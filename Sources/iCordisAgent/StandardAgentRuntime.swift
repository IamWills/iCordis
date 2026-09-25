import Foundation
import iCordisKernel

/// Concrete implementation owned by StandardAgentLoopPlugin. It is not a
/// Product service and is never registered in the Kernel directly.
public actor StandardAgentRuntime {
  private let services: ServiceRegistry?
  private let runtime: InferenceRuntimeProtocol
  private let orchestrator: any CapabilityInvoking
  private let builtinRegistry: any AgentBuiltinToolProviding
  private let instructionSkillService: (any AgentInstructionSkillProviding)?
  private let registeredAppService: (any AgentRegisteredAppProviding)?
  private let localAppInteractor: AgentLocalAppInteracting?
  private let configuration: AgentConfiguration
  private let requestShaper: AgentRequestShaper
  private let traceStore = AgentTraceStore()
  private var runningTasks: [UUID: RunningAgentTask] = [:]

  public init(
    runtime: InferenceRuntimeProtocol,
    orchestrator: any CapabilityInvoking,
    builtinRegistry: any AgentBuiltinToolProviding,
    instructionSkillService: (any AgentInstructionSkillProviding)? = nil,
    registeredAppService: (any AgentRegisteredAppProviding)? = nil,
    localAppInteractor: AgentLocalAppInteracting? = nil,
    configuration: AgentConfiguration = .production,
    requestShaper: AgentRequestShaper = .passthrough,
    services: ServiceRegistry? = nil
  ) {
    self.services = services
    self.runtime = runtime
    self.orchestrator = orchestrator
    self.builtinRegistry = builtinRegistry
    self.instructionSkillService = instructionSkillService
    self.registeredAppService = registeredAppService
    self.localAppInteractor = localAppInteractor
    self.configuration = configuration
    self.requestShaper = requestShaper
  }

  public func run(
    session: ConversationSession,
    task: String,
    model: LocalModelDescriptor,
    settings: AppSettings,
    capabilityDescriptors: [CapabilityDescriptor],
    memoryContext: LongTermMemoryContext = .empty,
    resolvedTaskIntent: AgentTaskIntent? = nil
  ) async throws -> AsyncThrowingStream<StreamEvent, Error> {
    let cleanTask = task.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !cleanTask.isEmpty else {
      throw AgentError.emptyTask
    }

    let effectiveConfiguration = configuration.applying(settings: settings)
    let llmClient = AgentLLMClient(
      runtime: runtime, requestShaper: requestShaper, services: services)
    let taskIntent: AgentTaskIntent
    if let resolvedTaskIntent {
      taskIntent = resolvedTaskIntent
    } else {
      // Agent routing depends on this decision. Do not silently classify
      // a failed parse as `general`, because that would replace the
      // model's semantic decision with an unrelated default.
      taskIntent = try await llmClient.resolveTaskIntent(
        sessionID: session.id,
        modelID: model.id,
        session: session,
        currentRequest: cleanTask,
        parameters: session.parameters
      )
    }
    let instructionSkillContext: InstructionSkillContext
    if settings.enableSkills, let instructionSkillService {
      do {
        instructionSkillContext = try await instructionSkillService.context(
          for: taskIntent.objective,
          sessionID: session.id
        )
      } catch {
        AgentLogCategory.app.error(
          "instruction skill activation failed session=\(session.id.uuidString) error=\(error.localizedDescription)"
        )
        instructionSkillContext = .empty
      }
    } else {
      if let instructionSkillService {
        await instructionSkillService.deactivate(sessionID: session.id)
      }
      instructionSkillContext = .empty
    }
    // Tier-1 context gating input: driving an App's UI only makes sense once
    // one is registered, so this is checked before the run rather than being
    // discovered through a failed tool call.
    let hasRegisteredApps: Bool
    if let registeredAppService {
      hasRegisteredApps = ((try? await registeredAppService.listApps()) ?? []).isEmpty == false
    } else {
      hasRegisteredApps = false
    }
    let builtinDescriptors = await builtinRegistry.descriptors()
    let catalog = AgentToolCatalog(descriptors: builtinDescriptors + capabilityDescriptors)
    let executor = AgentToolExecutor(
      orchestrator: orchestrator,
      settings: settings,
      catalog: catalog,
      builtinRegistry: builtinRegistry,
      currentSession: session,
      timeout: effectiveConfiguration.toolTimeout
    )
    let continuationService = try await services?.optional(RuntimeServices.continuation) ?? .decline
    let bridgeService = try await services?.optional(RuntimeServices.toolBridge)
    let copy = try await services?.optional(RuntimeServices.transcriptCopy) ?? .neutral
    let reasoningPresentation =
      try await services?.optional(RuntimeServices.reasoningPresentation)?.presentation
      ?? .typedEvent
    let loop = AgentLoop(
      continuation: continuationService,
      toolBridge: bridgeService,
      configuration: effectiveConfiguration,
      llmClient: llmClient,
      toolExecutor: executor,
      catalog: catalog,
      memoryContext: memoryContext,
      instructionSkillContext: instructionSkillContext,
      autonomousSkillLearningMode: settings.enableSkills
        ? settings.autonomousSkillLearningMode : .off,
      localAppInteractor: localAppInteractor,
      renderingMode: Self.renderingMode(for: model),
      availability: AgentToolAvailability.resolve(
        session: session,
        settings: settings,
        hasRegisteredApps: hasRegisteredApps
      ),
      runSettings: settings,
      hasRegisteredApps: hasRegisteredApps,
      acceptsImageInput: model.modality == .visionLanguage,
      completionGate: AgentCompletionGate(
        registeredAppService: registeredAppService
      ),
      copy: copy,
      reasoningPresentation: reasoningPresentation
    )
    let traceStore = self.traceStore

    let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream(
      bufferingPolicy: .unbounded
    )
    let messageID = UUID()
    let responseID = UUID()
    let runToken = UUID()
    let outputState = AgentAnswerOutputState()
    let responseEmitter = AgentResponsesEmitter(
      responseID: responseID,
      messageID: messageID,
      conversationID: session.protocolMetadata[ResponsesAIOutputSpec.conversationIDMetadataKey]?
        .stringValue
        ?? ResponsesAIOutputSpec.makeConversationID(sessionID: session.id),
      continuation: continuation
    )
    await responseEmitter.start()
    RuntimeProgressNotification.post(
      backend: "William Agent", detail: "Agent is planning…", progressFraction: nil)

    let task = Task {
      do {
        let summary = try await loop.run(
          session: session,
          taskIntent: taskIntent,
          modelID: model.id
        ) { event in
          switch event {
          case .capabilityInvocationStarted(let progress):
            RuntimeProgressNotification.post(
              backend: "William Agent",
              detail: "Invoking \(progress.request.capabilityID)…",
              progressFraction: nil,
              capabilityID: progress.request.capabilityID,
              toolPhase: .started
            )
            await responseEmitter.emit(progress: progress)
          case .capabilityInvocation(let trace):
            RuntimeProgressNotification.post(
              backend: "William Agent",
              detail: "Invoked \(trace.request.capabilityID)",
              progressFraction: nil,
              capabilityID: trace.request.capabilityID,
              toolPhase: .finished
            )
            await responseEmitter.emit(trace: trace)
            // Responses events drive the visible timeline;
            // the typed event is retained for session-level
            // diagnostics and post-run inspection.
            continuation.yield(.capabilityInvocation(trace))
          case .textDelta(_, let delta):
            await outputState.observe(delta: delta)
            await responseEmitter.emit(delta: delta)
          case .reasoningDelta(_, let delta):
            continuation.yield(.reasoningDelta(messageID: messageID, delta: delta))
            await responseEmitter.emitReasoning(delta: delta)
          default:
            break
          }
        }

        let answer = summary.finalAnswer ?? "Agent finished without a final answer."
        let completionDetail =
          summary.completionStatus == .completed
          ? "Agent completed"
          : "Agent finished with status \(summary.completionStatus.rawValue)"
        RuntimeProgressNotification.post(
          backend: "William Agent", detail: completionDetail, progressFraction: 1)
        // The loop keeps the already-streamed proposal as finalAnswer,
        // so a mismatch here means the answer never reached the UI
        // (stall/checkpoint synthesis). Do not use this path to publish
        // controller rewrites — that regressed into one-shot dumps.
        let didStreamResolvedAnswer = await outputState.hasEmitted(answer: answer)
        AgentLogCategory.app.debug(
          "agent run completed finalChars=\(answer.count) "
            + "resolvedAnswerAlreadyStreamed=\(didStreamResolvedAnswer)"
        )
        if didStreamResolvedAnswer == false {
          await responseEmitter.emit(delta: answer)
        }
        let summaryTrace = traceStore.makeSummaryTrace(from: summary)
        continuation.yield(.capabilityInvocation(summaryTrace))
        AgentLogCategory.capability.info(
          "agent run summary run=\(summary.id.uuidString) session=\(summary.sessionID.uuidString) "
            + "status=\(summary.completionStatus.rawValue) steps=\(summary.steps.count) "
            + "durationMs=\(Int(summary.finishedAt.timeIntervalSince(summary.startedAt) * 1_000))"
        )
        await responseEmitter.complete(usage: .zero)
        continuation.finish()
      } catch is CancellationError {
        RuntimeProgressNotification.post(
          backend: "William Agent", detail: "Agent cancelled", progressFraction: nil)
        await responseEmitter.fail(message: AgentError.cancelled.userFacingMessage)
        continuation.finish()
      } catch {
        let message = UserFacingErrorMapper.message(for: error)
        RuntimeProgressNotification.post(
          backend: "William Agent", detail: message, progressFraction: nil)
        await responseEmitter.fail(message: message)
        continuation.finish()
      }
    }
    // Register synchronously on the actor before handing the stream to the
    // UI. Otherwise Stop can clear an empty slot and a detached registration
    // can subsequently make the request live again.
    setRunningTask(task, token: runToken, for: session.id)

    continuation.onTermination = { termination in
      let wasCancelled: Bool
      switch termination {
      case .cancelled:
        wasCancelled = true
      case .finished:
        wasCancelled = false
      @unknown default:
        wasCancelled = true
      }
      if wasCancelled {
        task.cancel()
      }
      Task {
        await self.clearRunningTask(token: runToken, for: session.id)
        if wasCancelled {
          await self.runtime.cancelGeneration(sessionID: session.id)
        }
      }
    }
    return stream
  }

  /// Hosted Responses models carry real tool calling, so the Agent lets the
  /// protocol decide what is a tool call and what is the end of the run.
  /// On-device backends still have to negotiate that in prose.
  private static func renderingMode(for model: LocalModelDescriptor)
    -> AgentTrajectory.RenderingMode
  {
    model.format == .responsesAPI ? .nativeToolCalls : .textProtocol
  }

  public func cancelGeneration(sessionID: UUID) async {
    let running = runningTasks[sessionID]
    runningTasks[sessionID] = nil
    running?.task.cancel()
    await runtime.cancelGeneration(sessionID: sessionID)
    if let running {
      await running.task.value
    }
  }

  public func shutdown() async {
    let active = runningTasks
    runningTasks.removeAll()
    for (sessionID, running) in active {
      running.task.cancel()
      await runtime.cancelGeneration(sessionID: sessionID)
    }
    for running in active.values {
      await running.task.value
    }
  }

  private func setRunningTask(_ task: Task<Void, Never>, token: UUID, for sessionID: UUID) {
    runningTasks[sessionID]?.task.cancel()
    runningTasks[sessionID] = RunningAgentTask(token: token, task: task)
  }

  private func clearRunningTask(token: UUID, for sessionID: UUID) {
    if runningTasks[sessionID]?.token == token {
      runningTasks[sessionID] = nil
    }
  }
}

private struct RunningAgentTask {
  let token: UUID
  let task: Task<Void, Never>
}

private actor AgentResponsesEmitter {
  private let responseID: UUID
  private let conversationID: String
  private let continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
  private var sequence = 0
  private var messageID: UUID
  private var text = ""
  private var didOpenMessage = false
  private var didFinish = false

  init(
    responseID: UUID,
    messageID: UUID,
    conversationID: String? = nil,
    continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
  ) {
    self.responseID = responseID
    self.messageID = messageID
    self.conversationID =
      conversationID ?? ResponsesAIOutputSpec.makeConversationID(sessionID: messageID)
    self.continuation = continuation
  }

  func start() {
    append(.responseCreated(responseID: responseID))
    append(.responseQueued(responseID: responseID))
    append(.responseInProgress(responseID: responseID))
  }

  func emit(delta: String) {
    guard !delta.isEmpty else { return }
    openMessageIfNeeded()
    text += delta
    append(.outputTextDelta(responseID: responseID, messageID: messageID, delta: delta))
  }

  func emitReasoning(delta: String) {
    guard !delta.isEmpty else { return }
    append(.reasoningTextDelta(responseID: responseID, messageID: messageID, delta: delta))
  }

  func emit(trace: CapabilityExecutionTrace) {
    guard trace.request.capabilityID != "agent.run" else { return }
    for event in ResponseStreamEvent.functionCallOutput(responseID: responseID, trace: trace) {
      append(event)
    }
  }

  func emit(progress: CapabilityInvocationProgress) {
    guard progress.request.capabilityID != "agent.run" else { return }
    // A tool call is an output-item boundary.  Closing the preceding message
    // prevents the final response event from reusing its accumulated text and
    // lets consumers keep already-rendered assistant segments immutable.
    finishOpenMessageIfNeeded()
    let itemID = ResponsesAIOutputSpec.functionCallID(progress.id)
    append(
      ResponseStreamEvent(
        type: "response.output_item.added",
        responseID: ResponsesAIOutputSpec.responseID(responseID),
        itemID: itemID,
        outputIndex: 0,
        item: .init(
          id: itemID,
          type: "function_call",
          status: "in_progress",
          name: progress.request.capabilityID,
          callID: ResponsesAIOutputSpec.callID(progress.id),
          arguments: Self.compactJSONString(from: progress.request.arguments)
        )
      ))
  }

  func complete(usage: Usage) {
    let alreadyFinished = didFinish
    didFinish = true
    guard !alreadyFinished else { return }
    let finalMessage = finishOpenMessageIfNeeded()
    append(
      .responseCompleted(
        responseID: responseID,
        messageID: finalMessage?.id,
        text: finalMessage?.text,
        usage: usage
      ))
  }

  func fail(message: String) {
    append(
      .responseFailed(
        responseID: responseID, messageID: didOpenMessage ? messageID : nil, description: message))
  }

  private func openMessageIfNeeded() {
    let shouldOpen = !didOpenMessage
    didOpenMessage = true
    guard shouldOpen else { return }
    append(.messageOutputItemAdded(responseID: responseID, messageID: messageID))
    append(.contentPartAdded(responseID: responseID, messageID: messageID))
  }

  /// Ends only the current text output item.  A later text delta will allocate a
  /// fresh message ID, so text emitted after a tool call can never replace text
  /// already shown before it.
  @discardableResult
  private func finishOpenMessageIfNeeded() -> (id: UUID, text: String)? {
    let shouldFinish = didOpenMessage
    let finishedMessageID = messageID
    let finishedText = text
    if shouldFinish {
      didOpenMessage = false
      messageID = UUID()
      text = ""
    }
    guard shouldFinish else { return nil }
    append(
      .outputTextDone(responseID: responseID, messageID: finishedMessageID, text: finishedText))
    append(
      .contentPartDone(responseID: responseID, messageID: finishedMessageID, text: finishedText))
    append(
      .messageOutputItemDone(
        responseID: responseID, messageID: finishedMessageID, text: finishedText))
    return (finishedMessageID, finishedText)
  }

  private func append(_ event: ResponseStreamEvent) {
    sequence += 1
    let nextSequence = sequence

    var event = event
    event.sequenceNumber = event.sequenceNumber ?? nextSequence
    event.conversationID = event.conversationID ?? conversationID
    continuation.yield(.responseEvent(event))
  }

  private static func compactJSONString(from value: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}

public actor AgentAnswerOutputState {
  public init() {}
  private var streamedAnswerText = ""
  private var isInsideReasoning = false
  private var pending = ""

  public func observe(delta: String) {
    pending += delta

    while pending.isEmpty == false {
      if isInsideReasoning {
        guard let closeTag = firstReasoningCloseTag(in: pending) else {
          pending = retainedTagPrefixSuffix(in: pending, tagPrefixes: reasoningCloseTags) ?? ""
          return
        }
        pending.removeSubrange(pending.startIndex..<closeTag.upperBound)
        isInsideReasoning = false
        continue
      }

      guard let openTag = firstReasoningOpenTag(in: pending) else {
        if let retained = retainedTagPrefixSuffix(
          in: pending, tagPrefixes: reasoningOpenTagPrefixes)
        {
          appendAnswerText(String(pending.dropLast(retained.count)))
          pending = retained
        } else {
          appendAnswerText(pending)
          pending.removeAll(keepingCapacity: true)
        }
        return
      }

      appendAnswerText(String(pending[..<openTag.lowerBound]))
      pending.removeSubrange(pending.startIndex..<openTag.upperBound)
      isInsideReasoning = true
    }
  }

  public func hasEmitted(answer: String) -> Bool {
    AgentVisibleAnswerMatcher.containsEquivalentAnswer(
      in: streamedAnswerText,
      answer: answer
    )
  }

  private func appendAnswerText(_ text: String) {
    streamedAnswerText += text
  }

  private func firstReasoningOpenTag(in text: String) -> Range<String.Index>? {
    firstTag(in: text, prefixes: reasoningOpenTagPrefixes)
  }

  private func firstReasoningCloseTag(in text: String) -> Range<String.Index>? {
    reasoningCloseTags.compactMap { text.range(of: $0, options: [.caseInsensitive]) }
      .min { $0.lowerBound < $1.lowerBound }
  }

  private func firstTag(in text: String, prefixes: [String]) -> Range<String.Index>? {
    prefixes.compactMap { prefix -> Range<String.Index>? in
      guard let prefixRange = text.range(of: prefix, options: [.caseInsensitive]),
        let end = text[prefixRange.upperBound...].firstIndex(of: ">")
      else {
        return nil
      }
      return prefixRange.lowerBound..<text.index(after: end)
    }
    .min { $0.lowerBound < $1.lowerBound }
  }

  private var reasoningOpenTagPrefixes: [String] {
    ["<reasoning", "<thinking", "<think"]
  }

  private var reasoningCloseTags: [String] {
    ["</reasoning>", "</thinking>", "</think>"]
  }

  private func retainedTagPrefixSuffix(in text: String, tagPrefixes: [String]) -> String? {
    let lowercasedText = text.lowercased()
    return
      tagPrefixes
      .flatMap { tag in
        (1...min(tag.count, text.count)).compactMap { length -> String? in
          let suffix = String(lowercasedText.suffix(length))
          return tag.hasPrefix(suffix) ? String(text.suffix(length)) : nil
        }
      }
      .max { $0.count < $1.count }
  }
}

extension AgentConfiguration {
  fileprivate func applying(settings: AppSettings) -> AgentConfiguration {
    var configuration = self
    configuration.maxIterations = min(max(settings.agentMaxIterations, 1), 32)
    configuration.maxToolCalls = min(max(settings.agentMaxToolCalls, 1), 64)
    return configuration
  }
}
