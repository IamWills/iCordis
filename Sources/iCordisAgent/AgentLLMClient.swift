import Foundation
import iCordisKernel

/// One tool call the model asked for, with the protocol call ID that must be
/// echoed back alongside its result.
public struct AgentInvocationRequest: Sendable, Hashable {
  public var callID: String
  public var call: AgentToolCall

  public init(callID: String, call: AgentToolCall) {
    self.callID = callID
    self.call = call
  }
}

/// The complete result of one model turn.
///
/// `toolCalls` being empty makes the text a candidate final answer. The Agent
/// loop asks a separate completion judge before treating it as terminal.
public struct AgentModelTurn: Sendable {
  public var visibleText: String
  /// Full model text, needed only by the text-protocol fallback.
  public var rawText: String
  public var toolCalls: [AgentInvocationRequest]
  public var usage: Usage?
  public var requestedOutputTokenLimit: Int
  public var providerReportedOutputLimit: Bool

  public var reachedOutputTokenLimit: Bool {
    providerReportedOutputLimit || (usage?.outputTokens ?? 0) >= requestedOutputTokenLimit
  }

  public init(
    visibleText: String, rawText: String, toolCalls: [AgentInvocationRequest], usage: Usage? = nil,
    requestedOutputTokenLimit: Int, providerReportedOutputLimit: Bool
  ) {
    self.visibleText = visibleText
    self.rawText = rawText
    self.toolCalls = toolCalls
    self.usage = usage
    self.requestedOutputTokenLimit = requestedOutputTokenLimit
    self.providerReportedOutputLimit = providerReportedOutputLimit
  }
}

public actor AgentLLMClient {
  public static let outputTokenLimit = 10_240
  private static let completionDecisionTokenLimit = 768
  private static let runStopTokenLimit = 256
  private static let contextCompressionTokenLimit = 1_024
  private static let taskIntentTokenLimit = 768

  private let services: ServiceRegistry?
  private let runtime: InferenceRuntimeProtocol
  private let requestShaper: AgentRequestShaper

  public init(
    runtime: InferenceRuntimeProtocol, requestShaper: AgentRequestShaper = .passthrough,
    services: ServiceRegistry? = nil
  ) {
    self.services = services
    self.runtime = runtime
    self.requestShaper = requestShaper
  }

  /// Resolves task meaning before runtime policy is selected. The model emits
  /// a closed schema; the parser then verifies that any resumed run is one of
  /// the real candidates supplied by William.
  public func resolveTaskIntent(
    sessionID: UUID,
    modelID: UUID,
    session: ConversationSession,
    currentRequest: String,
    parameters: InferenceParameters
  ) async throws -> AgentTaskIntent {
    RuntimeProgressNotification.post(
      backend: "William Agent",
      detail: "Agent is interpreting the task…",
      progressFraction: nil
    )
    let candidates = AgentRunIntentCandidate.recent(from: session)
    let context = session.items.suffix(12).map { item in
      "\(item.role.rawValue): \(item.plainText)"
    }.joined(separator: "\n")
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let candidateData = try encoder.encode(candidates)
    let candidateJSON = String(decoding: candidateData, as: UTF8.self)
    let messages = [
      ConversationItem(
        role: .system,
        content: [.text(PromptStore().prompt(for: .agentTaskIntent))],
        status: .completed
      ),
      ConversationItem(
        role: .user,
        content: [
          .text(
            """
            Current request:
            \(currentRequest)

            Recent conversation:
            \(context.isEmpty ? "No previous messages." : context)

            Candidate Agent runs (the only valid sources for related_run_id):
            \(candidateJSON)
            """)
        ],
        status: .completed
      ),
    ]

    var intentParameters = parameters
    intentParameters.stream = true
    intentParameters.temperature = 0
    intentParameters.topP = min(parameters.topP, 0.2)
    intentParameters.maxTokens = Self.taskIntentTokenLimit
    var protocolMetadata = session.protocolMetadata
    protocolMetadata["responses.conversation_id"] = nil
    protocolMetadata["william.request.kind"] = .string("agent_task_intent")
    let stringEnum: ([String]) -> JSONValue = { values in
      .object([
        "type": .string("string"),
        "enum": .array(values.map(JSONValue.string)),
      ])
    }
    let request = AIRequest(
      sessionID: sessionID,
      modelID: modelID,
      outputPreference: .responses,
      messages: messages,
      parameters: intentParameters,
      capabilityDescriptors: [],
      structuredOutputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "relationship": stringEnum(AgentTaskRelationship.allCases.map(\.rawValue)),
          "task_kind": stringEnum(AgentTaskKind.allCases.map(\.rawValue)),
          "execution_mode": stringEnum(AgentExecutionMode.allCases.map(\.rawValue)),
          "web_content_mode": stringEnum(AgentWebContentMode.allCases.map(\.rawValue)),
          "objective": .object(["type": .string("string")]),
          "related_run_id": .object(["type": .string("string")]),
        ]),
        "required": .array([
          .string("relationship"), .string("task_kind"),
          .string("execution_mode"), .string("web_content_mode"),
          .string("objective"), .string("related_run_id"),
        ]),
        "additionalProperties": .bool(false),
      ]),
      protocolMetadata: protocolMetadata
    )

    let stream = try await runtime.generate(request: request)
    var reducer = NativeAgentStreamReducer()
    var output = ""
    for try await event in stream {
      switch event {
      case .responseEvent(let responseEvent):
        if let failure = ResponsesTextStreamReducer.failureMessage(from: responseEvent) {
          throw InferenceError.runtimeFailure(failure)
        }
        output += reducer.consume(responseEvent).map(\.text).joined()
      case .textDelta(_, let delta):
        output += delta
      case .failed(_, let description):
        throw InferenceError.runtimeFailure(description)
      default:
        break
      }
    }
    let intent = try AgentTaskIntentParser().parse(
      output,
      currentRequest: currentRequest,
      candidates: candidates
    )
    AgentLogCategory.capability.debug(
      "semantic task intent relationship=\(intent.relationship.rawValue) "
        + "kind=\(intent.kind.rawValue) execution=\(intent.executionMode.rawValue) "
        + "run=\(intent.relatedRunID?.uuidString ?? "none")"
    )
    return intent
  }

  public func completeTurn(
    sessionID: UUID,
    modelID: UUID,
    session: ConversationSession,
    messages: [ConversationItem],
    parameters: InferenceParameters,
    catalog: AgentToolCatalog,
    resolutionCatalog: AgentToolCatalog? = nil,
    mode: AgentTrajectory.RenderingMode,
    onVisibleTextDelta: (@Sendable (AgentVisibleTextDelta) async -> Void)? = nil
  ) async throws -> AgentModelTurn {
    // One request-shaping seam: build a neutral draft and let the shaper apply
    // the canonical agent-turn policy (stream, cool temperature, output budget,
    // `william.request.kind`) and the `model/request` waterfall. The DSH bridge
    // shapes through the same seam, so the two paths cannot drift apart.
    // Declaring the tools natively is what lets the protocol — rather than a
    // JSON-in-prose parser — decide whether this turn is a tool call or the end.
    let draft = AgentModelRequestDraft(
      sessionID: sessionID,
      modelID: modelID,
      kind: .agentTurn,
      messages: messages,
      capabilities: mode == .nativeToolCalls ? catalog.allDescriptors : [],
      parameters: parameters,
      protocolMetadata: session.protocolMetadata
    )
    let request = try await requestShaper.shape(draft)

    let stream = try await runtime.generate(request: request)
    var usage: Usage?
    var providerReportedOutputLimit = false
    var nativeReducer = NativeAgentStreamReducer()
    var textReducer = ResponsesTextStreamReducer()
    var textExtractor = StreamingAgentVisibleTextExtractor()
    var rawText = ""
    var visibleText = ""

    for try await event in stream {
      switch event {
      case .responseEvent(let responseEvent):
        let reportsOutputLimit = Self.reportsOutputLimit(responseEvent)
        providerReportedOutputLimit = providerReportedOutputLimit || reportsOutputLimit
        if reportsOutputLimit == false,
          let failureMessage = ResponsesTextStreamReducer.failureMessage(from: responseEvent)
        {
          throw InferenceError.runtimeFailure(failureMessage)
        }

        switch mode {
        case .nativeToolCalls:
          // Text and tool calls arrive as separate output items, so
          // visible prose needs no un-mixing: every text delta is
          // already exactly what the user should see.
          for delta in nativeReducer.consume(responseEvent) {
            if delta.isReasoning == false {
              visibleText += delta.text
            }
            rawText += delta.text
            await onVisibleTextDelta?(delta)
          }
        case .textProtocol:
          for delta in textReducer.consume(responseEvent) {
            rawText += delta
            for visibleDelta in textExtractor.consume(delta) {
              if visibleDelta.isReasoning == false {
                visibleText += visibleDelta.text
              }
              await onVisibleTextDelta?(visibleDelta)
            }
          }
        }

        if let responseUsage = Self.usage(from: responseEvent.response?.usage) {
          usage = responseUsage
        }
      case .usage(let streamedUsage):
        usage = streamedUsage
      case .textDelta(_, let delta):
        AgentLogCategory.app.debug("ignored legacy agent textDelta chars=\(delta.count)")
      case .failed(_, let description):
        AgentLogCategory.app.debug("ignored legacy agent failure chars=\(description.count)")
      default:
        break
      }
    }

    let toolCalls =
      mode == .nativeToolCalls
      ? nativeReducer.finishedToolCalls(catalog: resolutionCatalog ?? catalog)
      : []
    AgentLogCategory.capability.debug(
      "agent turn mode=\(mode == .nativeToolCalls ? "native" : "text") "
        + "visibleChars=\(visibleText.count) toolCalls=\(toolCalls.count)"
    )
    return AgentModelTurn(
      visibleText: visibleText,
      rawText: rawText,
      toolCalls: toolCalls,
      usage: usage,
      requestedOutputTokenLimit: request.parameters.maxTokens,
      providerReportedOutputLimit: providerReportedOutputLimit
    )
  }

  public func progressSummary(_ turns: [AgentProgressTurn]) async throws -> String {
    let provider = try await services?.optional(RuntimeServices.agentProgress) ?? .standard
    return provider.summarize(turns)
  }

  public func judgeCompletion(
    sessionID: UUID,
    modelID: UUID,
    session: ConversationSession,
    messages: [ConversationItem],
    parameters: InferenceParameters
  ) async throws -> AgentCompletionDecision {
    var judgeParameters = parameters
    judgeParameters.stream = true
    judgeParameters.temperature = 0
    judgeParameters.topP = min(parameters.topP, 0.2)
    judgeParameters.maxTokens = Self.completionDecisionTokenLimit

    var protocolMetadata = session.protocolMetadata
    protocolMetadata["responses.conversation_id"] = nil
    protocolMetadata["william.request.kind"] = .string("agent_completion_judge")
    let request = AIRequest(
      sessionID: sessionID,
      modelID: modelID,
      outputPreference: .responses,
      messages: messages,
      parameters: judgeParameters,
      capabilityDescriptors: [],
      structuredOutputSchema: AgentCompletionDecision.schema,
      protocolMetadata: protocolMetadata
    )

    if let services, let completion = try await services.optional(RuntimeServices.agentCompletion) {
      return try await completion.review(request)
    }
    let stream = try await runtime.generate(request: request)
    var reducer = NativeAgentStreamReducer()
    var output = ""
    for try await event in stream {
      switch event {
      case .responseEvent(let responseEvent):
        if let failure = ResponsesTextStreamReducer.failureMessage(from: responseEvent) {
          throw InferenceError.runtimeFailure(failure)
        }
        output += reducer.consume(responseEvent).map(\.text).joined()
      case .textDelta(_, let delta):
        output += delta
      case .failed(_, let description):
        throw InferenceError.runtimeFailure(description)
      default:
        break
      }
    }
    let decision = try AgentCompletionDecisionParser().parse(output)
    AgentLogCategory.capability.debug(
      "agent completion judge shouldContinue=\(decision.shouldContinue) "
        + "reason=\(decision.reason ?? "unspecified")"
    )
    return decision
  }

  public func composeRunStopMessage(
    sessionID: UUID,
    modelID: UUID,
    session: ConversationSession,
    messages: [ConversationItem],
    parameters: InferenceParameters
  ) async throws -> String {
    var stopParameters = parameters
    stopParameters.stream = true
    stopParameters.temperature = min(parameters.temperature, 0.4)
    stopParameters.topP = min(parameters.topP, 0.8)
    stopParameters.maxTokens = Self.runStopTokenLimit

    var protocolMetadata = session.protocolMetadata
    protocolMetadata["responses.conversation_id"] = nil
    protocolMetadata["william.request.kind"] = .string("agent_run_stop")
    let request = AIRequest(
      sessionID: sessionID,
      modelID: modelID,
      outputPreference: .responses,
      messages: messages,
      parameters: stopParameters,
      capabilityDescriptors: [],
      structuredOutputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "message": .object(["type": .string("string")])
        ]),
        "required": .array([.string("message")]),
      ]),
      protocolMetadata: protocolMetadata
    )

    let stream = try await runtime.generate(request: request)
    var reducer = NativeAgentStreamReducer()
    var output = ""
    for try await event in stream {
      switch event {
      case .responseEvent(let responseEvent):
        if let failure = ResponsesTextStreamReducer.failureMessage(from: responseEvent) {
          throw InferenceError.runtimeFailure(failure)
        }
        output += reducer.consume(responseEvent).map(\.text).joined()
      case .textDelta(_, let delta):
        output += delta
      case .failed(_, let description):
        throw InferenceError.runtimeFailure(description)
      default:
        break
      }
    }
    return try AgentRunStopMessageParser().parse(output)
  }

  public func compressPromptContext(
    sessionID: UUID,
    modelID: UUID,
    session: ConversationSession,
    messages: [ConversationItem],
    parameters: InferenceParameters
  ) async throws -> String {
    var compressParameters = parameters
    compressParameters.stream = true
    compressParameters.temperature = min(parameters.temperature, 0.2)
    compressParameters.topP = min(parameters.topP, 0.6)
    compressParameters.maxTokens = Self.contextCompressionTokenLimit

    var protocolMetadata = session.protocolMetadata
    protocolMetadata["responses.conversation_id"] = nil
    protocolMetadata["william.request.kind"] = .string("agent_context_compress")
    let request = AIRequest(
      sessionID: sessionID,
      modelID: modelID,
      outputPreference: .responses,
      messages: messages,
      parameters: compressParameters,
      capabilityDescriptors: [],
      structuredOutputSchema: .object([
        "type": .string("object"),
        "properties": .object([
          "summary": .object(["type": .string("string")])
        ]),
        "required": .array([.string("summary")]),
      ]),
      protocolMetadata: protocolMetadata
    )

    let stream = try await runtime.generate(request: request)
    var reducer = NativeAgentStreamReducer()
    var output = ""
    for try await event in stream {
      switch event {
      case .responseEvent(let responseEvent):
        if let failure = ResponsesTextStreamReducer.failureMessage(from: responseEvent) {
          throw InferenceError.runtimeFailure(failure)
        }
        output += reducer.consume(responseEvent).map(\.text).joined()
      case .textDelta(_, let delta):
        output += delta
      case .failed(_, let description):
        throw InferenceError.runtimeFailure(description)
      default:
        break
      }
    }
    return try AgentContextCompressionParser().parse(output)
  }

  private static func usage(from payload: [String: JSONValue]?) -> Usage? {
    guard let payload,
      let inputTokens = number(from: payload["input_tokens"]),
      let outputTokens = number(from: payload["output_tokens"])
    else {
      return nil
    }
    let totalTokens = number(from: payload["total_tokens"]) ?? (inputTokens + outputTokens)
    return Usage(
      inputTokens: Int(inputTokens),
      outputTokens: Int(outputTokens),
      totalTokens: Int(totalTokens),
      tokensPerSecond: number(from: payload["tokens_per_second"])
    )
  }

  private static func number(from value: JSONValue?) -> Double? {
    guard case .number(let number)? = value else { return nil }
    return number
  }

  private static func reportsOutputLimit(_ event: ResponseStreamEvent) -> Bool {
    let isIncomplete = event.type == "response.incomplete" || event.response?.status == "incomplete"
    guard isIncomplete else { return false }
    let details = [
      event.message, strings(from: event.response?.incompleteDetails).joined(separator: " "),
    ]
    .compactMap { $0 }
    .joined(separator: " ")
    .lowercased()
    return details.contains("max_output_tokens")
      || details.contains("max_tokens")
      || details.contains("output token")
      || details.contains("length")
  }

  private static func strings(from value: JSONValue?) -> [String] {
    guard let value else { return [] }
    switch value {
    case .string(let string):
      return [string]
    case .object(let object):
      return object.values.flatMap { strings(from: $0) }
    case .array(let array):
      return array.flatMap { strings(from: $0) }
    case .number, .bool, .null:
      return []
    }
  }
}

/// Consumes a Responses stream in native tool-calling mode.
///
/// Text, reasoning and function calls are distinct output items in the
/// protocol, so this reducer only has to route them — it never has to guess
/// which characters of a token stream belong to a control payload.
public struct NativeAgentStreamReducer {
  private struct PendingCall {
    var name: String
    var callID: String
    var arguments = ""
    var isComplete = false
  }

  private var pendingCalls: [String: PendingCall] = [:]
  private var callOrder: [String] = []
  /// A Responses stream has exactly one visible-text source. Once any text
  /// delta arrives, terminal snapshots are metadata only and never contribute
  /// user-visible characters. A snapshot is retained solely as a compatibility
  /// fallback for providers that emit no text deltas at all.
  private var didReceiveTextDelta = false
  private var pendingSnapshotFallback: String?
  private var didEmitSnapshotFallback = false

  public mutating func consume(_ event: ResponseStreamEvent) -> [AgentVisibleTextDelta] {
    switch event.type {
    case "response.output_text.delta":
      return appendTextDelta(event.delta)
    case "response.output_text.done", "response.content_part.done":
      rememberSnapshotFallback(event.part?.text)
      return []
    case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
      guard let delta = event.delta, !delta.isEmpty else { return [] }
      return [AgentVisibleTextDelta(text: delta, isReasoning: true)]
    case "response.output_item.added":
      registerToolCall(event.item, itemKey: itemKey(for: event))
      return []
    case "response.function_call_arguments.delta":
      appendArguments(event.delta, itemKey: itemKey(for: event))
      return []
    case "response.function_call_arguments.done":
      completeArguments(
        event.arguments ?? event.item?.arguments ?? event.delta,
        itemKey: itemKey(for: event)
      )
      return []
    case "response.output_item.done":
      registerToolCall(event.item, itemKey: itemKey(for: event))
      completeArguments(event.item?.arguments, itemKey: itemKey(for: event))
      if event.item?.type == "message" {
        rememberSnapshotFallback(text(from: event.item))
      }
      return []
    case "response.completed":
      var completedText = ""
      for item in event.response?.output ?? [] {
        if item.type == "message" {
          completedText += text(from: item) ?? ""
        } else {
          let key = item.id ?? item.callID ?? UUID().uuidString
          registerToolCall(item, itemKey: key)
          completeArguments(item.arguments, itemKey: key)
        }
      }
      guard didReceiveTextDelta == false,
        didEmitSnapshotFallback == false
      else { return [] }
      let fallback = completedText.isEmpty ? pendingSnapshotFallback : completedText
      guard let fallback, !fallback.isEmpty else { return [] }
      pendingSnapshotFallback = nil
      didEmitSnapshotFallback = true
      return [AgentVisibleTextDelta(text: fallback, isReasoning: false)]
    default:
      return []
    }
  }

  public func finishedToolCalls(catalog: AgentToolCatalog) -> [AgentInvocationRequest] {
    callOrder.compactMap { key -> AgentInvocationRequest? in
      guard let pending = pendingCalls[key] else { return nil }
      let capabilityID = catalog.capabilityID(forFunctionName: pending.name) ?? pending.name
      return AgentInvocationRequest(
        callID: pending.callID,
        call: AgentToolCall(
          capabilityID: capabilityID,
          arguments: Self.decodeArguments(pending.arguments),
          rationale: nil
        )
      )
    }
  }

  private func itemKey(for event: ResponseStreamEvent) -> String {
    event.itemID
      ?? event.item?.id
      ?? event.item?.callID
      ?? event.outputIndex.map { "output:\($0)" }
      ?? "default"
  }

  private mutating func registerToolCall(
    _ item: ResponseStreamEvent.OutputItemPayload?,
    itemKey: String
  ) {
    guard let item, item.type == "function_call" else { return }
    if pendingCalls[itemKey] == nil {
      pendingCalls[itemKey] = PendingCall(
        name: item.name ?? "",
        callID: item.callID ?? item.id ?? itemKey
      )
      callOrder.append(itemKey)
    } else {
      if let name = item.name, !name.isEmpty {
        pendingCalls[itemKey]?.name = name
      }
      if let callID = item.callID, !callID.isEmpty {
        pendingCalls[itemKey]?.callID = callID
      }
    }
  }

  private mutating func appendArguments(_ delta: String?, itemKey: String) {
    guard let delta, !delta.isEmpty else { return }
    if pendingCalls[itemKey] == nil {
      // Some gateways stream argument deltas before announcing the item.
      pendingCalls[itemKey] = PendingCall(name: "", callID: itemKey)
      callOrder.append(itemKey)
    }
    guard pendingCalls[itemKey]?.isComplete == false else { return }
    pendingCalls[itemKey]?.arguments += delta
  }

  private mutating func completeArguments(_ arguments: String?, itemKey: String) {
    guard let arguments, !arguments.isEmpty, pendingCalls[itemKey] != nil else { return }
    // The terminal event carries the whole argument string; prefer it over
    // an accumulation that may have missed a delta.
    pendingCalls[itemKey]?.arguments = arguments
    pendingCalls[itemKey]?.isComplete = true
  }

  private mutating func appendTextDelta(_ text: String?) -> [AgentVisibleTextDelta] {
    guard let text, !text.isEmpty else { return [] }
    didReceiveTextDelta = true
    pendingSnapshotFallback = nil
    return [AgentVisibleTextDelta(text: text, isReasoning: false)]
  }

  private mutating func rememberSnapshotFallback(_ snapshot: String?) {
    guard didReceiveTextDelta == false,
      let snapshot,
      !snapshot.isEmpty
    else { return }
    // Later terminal events carry a more authoritative representation
    // (content part -> output item -> completed response), so keep the
    // latest snapshot until response.completed selects the fallback.
    pendingSnapshotFallback = snapshot
  }

  private func text(from item: ResponseStreamEvent.OutputItemPayload?) -> String? {
    let value =
      item?.content?
      .filter { $0.type == "output_text" || $0.type == "text" }
      .compactMap(\.text)
      .joined() ?? ""
    return value.isEmpty ? nil : value
  }

  private static func decodeArguments(_ raw: String) -> [String: JSONValue] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let data = trimmed.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let object) = value
    else {
      return [:]
    }
    return object
  }

  public init() {}
}

public struct ResponsesTextStreamReducer {
  private var text = ""

  public mutating func consume(_ event: ResponseStreamEvent) -> [String] {
    switch event.type {
    case "response.output_text.delta":
      return append(delta: event.delta)
    case "response.reasoning_text.delta", "response.reasoning_summary_text.delta":
      return appendReasoning(delta: event.delta)
    case "response.in_progress", "envelope.reasoning":
      return appendReasoning(delta: reasoningDelta(from: event))
    case "response.output_text.done":
      return append(fullText: event.part?.text)
    case "response.content_part.done":
      return append(fullText: event.part?.text)
    case "response.output_item.done":
      return append(fullText: text(from: event.item))
    case "response.completed":
      return append(fullText: text(from: event.response))
    default:
      return []
    }
  }

  private mutating func append(delta: String?) -> [String] {
    guard let delta, !delta.isEmpty else { return [] }
    text += delta
    return [delta]
  }

  private mutating func appendReasoning(delta: String?) -> [String] {
    guard let delta, !delta.isEmpty else { return [] }
    return append(delta: "<reasoning>\n\(delta)\n</reasoning>")
  }

  private mutating func append(fullText: String?) -> [String] {
    guard let fullText, !fullText.isEmpty else { return [] }
    guard !text.isEmpty else {
      text = fullText
      return [fullText]
    }
    if fullText.hasPrefix(text) {
      let delta = String(fullText.dropFirst(text.count))
      guard !delta.isEmpty else { return [] }
      text += delta
      return [delta]
    }
    if text.hasSuffix(fullText) {
      return []
    }
    return []
  }

  private func reasoningDelta(from event: ResponseStreamEvent) -> String? {
    guard let metadata = event.response?.metadata,
      case .object(let reasoning)? = metadata["reasoning"]
    else {
      return nil
    }
    return reasoning["delta"]?.stringValue
  }

  private func text(from item: ResponseStreamEvent.OutputItemPayload?) -> String? {
    guard item?.type == "message" else { return nil }
    let value =
      item?.content?
      .filter { $0.type == "output_text" || $0.type == "text" }
      .compactMap(\.text)
      .joined() ?? ""
    return value.isEmpty ? nil : value
  }

  private func text(from response: ResponseStreamEvent.ResponsePayload?) -> String? {
    let value =
      response?.output?
      .compactMap(text(from:))
      .joined() ?? ""
    return value.isEmpty ? nil : value
  }

  public static func failureMessage(from event: ResponseStreamEvent) -> String? {
    guard
      event.type == "error" || event.type == "response.failed"
        || event.type == "response.incomplete"
    else {
      return nil
    }
    if let message = event.message, !message.isEmpty {
      return message
    }
    if case .object(let object)? = event.error,
      let message = object["message"]?.stringValue,
      !message.isEmpty
    {
      return message
    }
    return nil
  }

  public init() {}
}

public struct AgentVisibleTextDelta: Sendable, Hashable {
  public var text: String
  public var isReasoning: Bool

  public init(text: String, isReasoning: Bool) {
    self.text = text
    self.isReasoning = isReasoning
  }
}

public enum AgentVisibleAnswerMatcher {
  public static func containsEquivalentAnswer(in emittedText: String, answer: String) -> Bool {
    let resolvedAnswer = comparisonText(answer)
    guard resolvedAnswer.isEmpty == false else { return true }
    let emittedAnswer = comparisonText(emittedText)
    if emittedAnswer.contains(resolvedAnswer) {
      return true
    }

    // A model can write the answer as prose immediately before its
    // final_answer JSON and then repeat it inside `content`, with only
    // Markdown whitespace or punctuation changing between the two copies.
    // Compare the tail so an earlier progress sentence does not prevent
    // recognizing that the actual answer has already been shown.
    guard resolvedAnswer.count >= 32 else { return false }
    let comparisonWindow = String(
      emittedAnswer.suffix(min(emittedAnswer.count, resolvedAnswer.count + 32))
    )
    return bigramCoverage(of: resolvedAnswer, in: comparisonWindow) >= 0.88
  }

  public static func areEquivalent(_ left: String, _ right: String) -> Bool {
    containsEquivalentAnswer(in: left, answer: right)
      || containsEquivalentAnswer(in: right, answer: left)
  }

  private static func comparisonText(_ text: String) -> String {
    String(
      text.lowercased().unicodeScalars.filter {
        CharacterSet.alphanumerics.contains($0)
      })
  }

  private static func bigramCoverage(of answer: String, in emittedText: String) -> Double {
    let answerBigrams = bigramCounts(answer)
    let emittedBigrams = bigramCounts(emittedText)
    let answerCount = answerBigrams.values.reduce(0, +)
    guard answerCount > 0 else { return 0 }
    let sharedCount = answerBigrams.reduce(into: 0) { result, entry in
      result += min(entry.value, emittedBigrams[entry.key, default: 0])
    }
    return Double(sharedCount) / Double(answerCount)
  }

  private static func bigramCounts(_ text: String) -> [String: Int] {
    let characters = Array(text)
    guard characters.count >= 2 else { return [:] }
    var counts: [String: Int] = [:]
    counts.reserveCapacity(characters.count - 1)
    for index in 0..<(characters.count - 1) {
      counts[String(characters[index...index + 1]), default: 0] += 1
    }
    return counts
  }
}

public struct StreamingAgentVisibleTextExtractor {
  private enum NaturalTextMode {
    case outsideControlPayloads
    case beforeControlPayload
  }

  private enum FinalAnswerEmissionMode {
    case undecided
    case emitting
    case suppressingDuplicate
  }

  private var buffer = ""
  private var contentStartOffset: Int?
  private var emittedCharacterCount = 0
  private var emittedNaturalTextCharacterCount = 0
  private var isFinalAnswer = false
  private var isToolCall = false
  private var explicitReasoningExtractor = StreamingExplicitReasoningExtractor()

  // Incremental scan state. Every one of these used to be recomputed from the
  // whole accumulated buffer on every delta — lowercasing it, walking it
  // character by character, and re-decoding the answer JSON — which made each
  // token O(total) and the stream O(n²). The agent runs this off the main
  // thread, so the symptom was a starved UI with an idle main thread rather
  // than a busy one.
  private var flagScanOffset = 0
  private var naturalMode: NaturalTextMode = .outsideControlPayloads
  private var naturalScanOffset = 0
  private var naturalOutputCount = 0
  private var pendingAnswerRaw = ""
  private var decodedAnswerCount = 0
  private var isAnswerEscaping = false
  private var didTerminateAnswer = false
  private var answerRawConsumedOffset = 0
  private var emittedNaturalText = ""
  private var deferredFinalAnswer = ""
  private var deferredFinalAnswerSemanticScalars: [Unicode.Scalar] = []
  private var naturalTextSemanticScalars: [Unicode.Scalar]?
  private var possibleDuplicateStarts: [Int]?
  private var finalAnswerEmissionMode: FinalAnswerEmissionMode = .undecided
  private var hiddenMarkupFilter = StreamingHiddenSystemMarkupFilter()

  /// Longest control marker minus one, re-scanned before newly appended text
  /// so a marker split across chunks is still detected.
  private static let flagOverlap = 11

  public mutating func consume(_ chunk: String) -> [AgentVisibleTextDelta] {
    let chunk = hiddenMarkupFilter.consume(chunk)
    let appendedStartOffset = buffer.count
    buffer += chunk
    var deltas = explicitReasoningExtractor.consume(chunk)
    updateControlFlags(appendedStartOffset: appendedStartOffset)
    if isFinalAnswer, !isToolCall {
      deltas.append(contentsOf: consumeFinalAnswerContent())
    } else if isToolCall {
      // Once this turn declares a tool call, only prose *before* the
      // control payload is valid progress text. Anything after the JSON is
      // speculative model continuation and must not jump ahead of the real
      // tool result or the later final_answer turn.
      deltas.append(contentsOf: consumeNaturalTextBeforeControlPayload())
    } else {
      // Do not wait for the model to finish its control object before
      // rendering prose that precedes it. `naturalTextOutsideControlPayloads`
      // stops at an incomplete JSON object, so it is safe to call for every
      // incoming chunk: prose is emitted immediately, while the partial
      // tool/final-answer JSON remains withheld until it is complete.
      //
      // Previously this ran only after "tool_call" was present in the
      // accumulated buffer. That turned each pre-tool explanation into one
      // large, delayed UI update.
      deltas.append(contentsOf: consumeNaturalTextOutsideControlPayloads())
    }

    return deltas
  }

  /// Scans only the newly appended text (plus a marker-length overlap) and
  /// stops entirely once both flags are known.
  private mutating func updateControlFlags(appendedStartOffset: Int) {
    guard !(isToolCall && isFinalAnswer) else { return }
    let start = max(flagScanOffset, appendedStartOffset - Self.flagOverlap, 0)
    let startIndex = buffer.index(buffer.startIndex, offsetBy: start)
    let region = buffer[startIndex...].lowercased()
    if region.contains("tool_call") {
      isToolCall = true
    }
    if region.contains("final_answer") {
      isFinalAnswer = true
    }
    flagScanOffset = max(0, buffer.count - Self.flagOverlap)
  }

  /// Decodes only raw content that has not been decoded yet, carrying escape
  /// state across chunks instead of re-decoding the whole answer each time.
  private mutating func consumeFinalAnswerContent() -> [AgentVisibleTextDelta] {
    if contentStartOffset == nil {
      contentStartOffset = findFinalAnswerStartOffset(in: buffer)
      if let contentStartOffset {
        answerRawConsumedOffset = contentStartOffset
      }
    }
    guard contentStartOffset != nil, !didTerminateAnswer else { return [] }

    let nsBuffer = buffer as NSString
    guard answerRawConsumedOffset < nsBuffer.length else { return [] }
    let newRaw = nsBuffer.substring(from: answerRawConsumedOffset)
    answerRawConsumedOffset = nsBuffer.length
    pendingAnswerRaw += newRaw

    var decoded = ""
    var index = pendingAnswerRaw.startIndex
    var consumedUpTo = pendingAnswerRaw.startIndex
    scan: while index < pendingAnswerRaw.endIndex {
      let character = pendingAnswerRaw[index]
      if isAnswerEscaping {
        switch character {
        case "\"": decoded.append("\"")
        case "\\": decoded.append("\\")
        case "/": decoded.append("/")
        case "n": decoded.append("\n")
        case "r": decoded.append("\r")
        case "t": decoded.append("\t")
        case "b": decoded.append("\u{0008}")
        case "f": decoded.append("\u{000C}")
        case "u":
          // Matches the previous behaviour: stop at an incomplete
          // unicode escape rather than emitting a partial one.
          break scan
        default: decoded.append(character)
        }
        isAnswerEscaping = false
        index = pendingAnswerRaw.index(after: index)
        consumedUpTo = index
        continue
      }
      if character == "\\" {
        let next = pendingAnswerRaw.index(after: index)
        guard next < pendingAnswerRaw.endIndex else { break scan }
        isAnswerEscaping = true
        index = next
        continue
      }
      if character == "\"" {
        didTerminateAnswer = true
        break scan
      }
      decoded.append(character)
      index = pendingAnswerRaw.index(after: index)
      consumedUpTo = index
    }
    pendingAnswerRaw.removeSubrange(pendingAnswerRaw.startIndex..<consumedUpTo)

    if decoded.isEmpty == false {
      decodedAnswerCount += decoded.count
      emittedCharacterCount = decodedAnswerCount
    }

    guard decoded.isEmpty == false || didTerminateAnswer else { return [] }
    return visibleFinalAnswerDeltas(decoded)
  }

  /// Models occasionally write the complete answer as ordinary prose and then
  /// repeat it inside `final_answer.content`. Hold only a short semantic prefix
  /// while testing that duplicate hypothesis. A distinct answer is released as
  /// soon as the prefix no longer occurs in the already-emitted prose, keeping
  /// normal final-answer streaming incremental.
  private mutating func visibleFinalAnswerDeltas(_ decoded: String) -> [AgentVisibleTextDelta] {
    switch finalAnswerEmissionMode {
    case .emitting:
      guard decoded.isEmpty == false else { return [] }
      return [AgentVisibleTextDelta(text: decoded, isReasoning: false)]
    case .suppressingDuplicate:
      return []
    case .undecided:
      break
    }

    guard emittedNaturalText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      finalAnswerEmissionMode = .emitting
      guard decoded.isEmpty == false else { return [] }
      return [AgentVisibleTextDelta(text: decoded, isReasoning: false)]
    }

    deferredFinalAnswer += decoded
    let previousSemanticCount = deferredFinalAnswerSemanticScalars.count
    deferredFinalAnswerSemanticScalars.append(contentsOf: semanticScalars(in: decoded))
    let semanticCount = deferredFinalAnswerSemanticScalars.count

    if naturalTextSemanticScalars == nil {
      naturalTextSemanticScalars = semanticScalars(in: emittedNaturalText)
    }
    let naturalScalars = naturalTextSemanticScalars ?? []

    if semanticCount >= Self.finalAnswerDedupProbeLength {
      if let starts = possibleDuplicateStarts {
        if semanticCount > previousSemanticCount {
          possibleDuplicateStarts = starts.filter { start in
            guard start + semanticCount <= naturalScalars.count else { return false }
            return naturalScalars[(start + previousSemanticCount)..<(start + semanticCount)]
              .elementsEqual(
                deferredFinalAnswerSemanticScalars[previousSemanticCount..<semanticCount])
          }
        }
      } else {
        possibleDuplicateStarts = matchingStarts(
          of: deferredFinalAnswerSemanticScalars,
          in: naturalScalars
        )
      }

      if possibleDuplicateStarts?.isEmpty == true {
        return beginEmittingDeferredFinalAnswer()
      }
    }

    guard didTerminateAnswer else { return [] }
    if possibleDuplicateStarts?.isEmpty == false,
      semanticCount >= Self.finalAnswerDedupProbeLength
    {
      finalAnswerEmissionMode = .suppressingDuplicate
      deferredFinalAnswer.removeAll(keepingCapacity: false)
      return []
    }
    if AgentVisibleAnswerMatcher.containsEquivalentAnswer(
      in: emittedNaturalText,
      answer: deferredFinalAnswer
    ) {
      finalAnswerEmissionMode = .suppressingDuplicate
      deferredFinalAnswer.removeAll(keepingCapacity: false)
      return []
    }
    return beginEmittingDeferredFinalAnswer()
  }

  private mutating func beginEmittingDeferredFinalAnswer() -> [AgentVisibleTextDelta] {
    finalAnswerEmissionMode = .emitting
    let text = deferredFinalAnswer
    deferredFinalAnswer.removeAll(keepingCapacity: false)
    guard text.isEmpty == false else { return [] }
    return [AgentVisibleTextDelta(text: text, isReasoning: false)]
  }

  private func semanticScalars(in text: String) -> [Unicode.Scalar] {
    text.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
  }

  private func matchingStarts(
    of needle: [Unicode.Scalar],
    in haystack: [Unicode.Scalar]
  ) -> [Int] {
    guard needle.isEmpty == false, needle.count <= haystack.count else { return [] }
    return (0...(haystack.count - needle.count)).filter { start in
      haystack[start..<(start + needle.count)].elementsEqual(needle)
    }
  }

  private static let finalAnswerDedupProbeLength = 24

  private mutating func consumeNaturalTextOutsideControlPayloads() -> [AgentVisibleTextDelta] {
    naturalTextDeltas(mode: .outsideControlPayloads)
  }

  private mutating func consumeNaturalTextBeforeControlPayload() -> [AgentVisibleTextDelta] {
    naturalTextDeltas(mode: .beforeControlPayload)
  }

  /// Resumes the natural-text walk from the last committed position instead of
  /// re-walking the whole buffer. The walk stops without advancing whenever it
  /// meets an incomplete construct, so a later chunk re-evaluates that spot.
  private mutating func naturalTextDeltas(mode: NaturalTextMode) -> [AgentVisibleTextDelta] {
    if mode != naturalMode {
      // The classification rule changed; restart the walk once so the
      // result matches a from-scratch evaluation under the new rule.
      naturalMode = mode
      naturalScanOffset = 0
      naturalOutputCount = 0
    }

    var index = buffer.index(buffer.startIndex, offsetBy: naturalScanOffset)
    var appended = ""
    walk: while index < buffer.endIndex {
      if mode == .beforeControlPayload {
        if buffer[index] == "{" { break walk }
        if tagRange(
          in: buffer,
          at: index,
          openPrefixes: ToolControlMarkup.openMarkers,
          closeTags: []
        ) != nil {
          break walk
        }
      } else if let fenceEnd = markdownFenceMarkerEnd(in: buffer, at: index) {
        // An unterminated fence line may still gain its newline later.
        guard fenceEnd < buffer.endIndex else { break walk }
        index = fenceEnd
        continue
      }

      if let reasoningRange = tagRange(
        in: buffer,
        at: index,
        openPrefixes: ["<reasoning", "<thinking", "<think"],
        closeTags: ["</reasoning>", "</thinking>", "</think>"]
      ) {
        guard let upperBound = reasoningRange.upperBound else { break walk }
        index = upperBound
        continue
      }

      if mode == .outsideControlPayloads {
        if let toolRange = tagRange(
          in: buffer,
          at: index,
          openPrefixes: ToolControlMarkup.openMarkers,
          closeTags: [
            "</william:tool_use>",
            "</tool_call>",
            "</tool_calls>",
            "</｜｜dsml｜｜l_call>",
            "</｜｜dsml｜｜tool_call>",
            "<|tool_call_end|>",
            "<|tool_calls_end|>",
            "<｜tool▁calls▁end｜>",
          ]
        ) {
          guard let upperBound = toolRange.upperBound else { break walk }
          index = upperBound
          continue
        }
      }

      if ToolControlMarkup.isIncompleteOpenMarker(buffer[index...]) { break walk }

      if mode == .outsideControlPayloads, buffer[index] == "{" {
        guard let objectEnd = balancedJSONObjectEnd(in: buffer, from: index) else { break walk }
        index = buffer.index(after: objectEnd)
        continue
      }

      appended.append(buffer[index])
      index = buffer.index(after: index)
    }
    naturalScanOffset = buffer.distance(from: buffer.startIndex, to: index)

    let previousTotal = naturalOutputCount
    naturalOutputCount += appended.count
    guard naturalOutputCount > emittedNaturalTextCharacterCount else { return [] }

    let newDelta: String
    if previousTotal == emittedNaturalTextCharacterCount {
      newDelta = appended
    } else {
      // Only after a mode restart: skip what was already emitted.
      newDelta = String(appended.dropFirst(emittedNaturalTextCharacterCount - previousTotal))
    }
    emittedNaturalTextCharacterCount = naturalOutputCount
    guard newDelta.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      return []
    }
    emittedNaturalText += newDelta
    return [AgentVisibleTextDelta(text: newDelta, isReasoning: false)]
  }

  private func findFinalAnswerStartOffset(in text: String) -> Int? {
    let nsText = text as NSString
    let acceptedKeys = ["content", "answer", "final", "response", "message"]
    let matchingRanges =
      acceptedKeys
      .map { nsText.range(of: "\"\($0)\"", options: [.caseInsensitive]) }
      .filter({ $0.location != NSNotFound })
    guard let contentRange = matchingRanges.min(by: { $0.location < $1.location }) else {
      return nil
    }

    let afterContent = NSRange(
      location: contentRange.location + contentRange.length,
      length: nsText.length - contentRange.location - contentRange.length
    )
    let colonRange = nsText.range(of: ":", options: [], range: afterContent)
    guard colonRange.location != NSNotFound else { return nil }

    let afterColon = NSRange(
      location: colonRange.location + colonRange.length,
      length: nsText.length - colonRange.location - colonRange.length
    )
    let quoteRange = nsText.range(of: "\"", options: [], range: afterColon)
    guard quoteRange.location != NSNotFound else { return nil }
    return quoteRange.location + quoteRange.length
  }

  private func decodePartialJSONString(_ raw: String) -> String {
    var decoded = ""
    var iterator = raw.makeIterator()
    var isEscaping = false

    while let character = iterator.next() {
      if isEscaping {
        switch character {
        case "\"": decoded.append("\"")
        case "\\": decoded.append("\\")
        case "/": decoded.append("/")
        case "n": decoded.append("\n")
        case "r": decoded.append("\r")
        case "t": decoded.append("\t")
        case "b": decoded.append("\u{0008}")
        case "f": decoded.append("\u{000C}")
        case "u":
          // Wait for a later chunk rather than emitting an incomplete unicode escape.
          return decoded
        default:
          decoded.append(character)
        }
        isEscaping = false
        continue
      }

      if character == "\\" {
        isEscaping = true
        continue
      }
      if character == "\"" {
        break
      }
      decoded.append(character)
    }

    return decoded
  }

  private func markdownFenceMarkerEnd(in text: String, at index: String.Index) -> String.Index? {
    guard text[index...].hasPrefix("```") else { return nil }
    return text[index...].firstIndex(of: "\n").map { text.index(after: $0) } ?? text.endIndex
  }

  private func tagRange(
    in text: String,
    at index: String.Index,
    openPrefixes: [String],
    closeTags: [String]
  ) -> (lowerBound: String.Index, upperBound: String.Index?)? {
    let remaining = text[index...]
    guard openPrefixes.contains(where: { remaining.lowercased().hasPrefix($0.lowercased()) }) else {
      return nil
    }
    guard let openEnd = remaining.firstIndex(of: ">") else {
      return (index, nil)
    }

    let afterOpen = text.index(after: openEnd)
    let closeRange =
      closeTags
      .compactMap {
        text.range(of: $0, options: [.caseInsensitive], range: afterOpen..<text.endIndex)
      }
      .min { $0.lowerBound < $1.lowerBound }
    return (index, closeRange?.upperBound)
  }

  private func balancedJSONObjectEnd(in text: String, from start: String.Index) -> String.Index? {
    var depth = 0
    var isInsideString = false
    var isEscaping = false
    var index = start

    while index < text.endIndex {
      let character = text[index]

      if isInsideString {
        if isEscaping {
          isEscaping = false
        } else if character == "\\" {
          isEscaping = true
        } else if character == "\"" {
          isInsideString = false
        }
      } else {
        if character == "\"" {
          isInsideString = true
        } else if character == "{" {
          depth += 1
        } else if character == "}" {
          depth -= 1
          if depth == 0 {
            return index
          }
        }
      }

      index = text.index(after: index)
    }

    return nil
  }

  public init() {}
}

/// Provider-side policy hints are control-plane data, not assistant output.
/// Strip them before either natural text or final-answer streaming sees them,
/// including when the tag is divided across response chunks.
private struct StreamingHiddenSystemMarkupFilter {
  private let openTagPrefix = "<system_warning"
  private let closeTag = "</system_warning>"
  private var pending = ""
  private var isInsideWarning = false

  mutating func consume(_ chunk: String) -> String {
    pending += chunk
    var output = ""

    while !pending.isEmpty {
      if isInsideWarning {
        guard let closeRange = pending.range(of: closeTag, options: [.caseInsensitive]) else {
          pending = retainedSuffix(in: pending, matchingPrefixOf: closeTag)
          return output
        }
        pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
        isInsideWarning = false
        continue
      }

      if let openRange = pending.range(of: openTagPrefix, options: [.caseInsensitive]) {
        output += String(pending[..<openRange.lowerBound])
        pending.removeSubrange(pending.startIndex..<openRange.upperBound)
        isInsideWarning = true
        continue
      }

      let retained = retainedSuffix(in: pending, matchingPrefixOf: openTagPrefix)
      let retainedCount = retained.count
      output += String(pending.dropLast(retainedCount))
      pending = retained
      return output
    }

    return output
  }

  private func retainedSuffix(in text: String, matchingPrefixOf marker: String) -> String {
    let lowercased = text.lowercased()
    let maximumLength = min(text.count, marker.count - 1)
    guard maximumLength > 0 else { return "" }
    for length in stride(from: maximumLength, through: 1, by: -1) {
      if marker.hasPrefix(String(lowercased.suffix(length))) {
        return String(text.suffix(length))
      }
    }
    return ""
  }
}

private struct StreamingExplicitReasoningExtractor {
  private var pending = ""
  private var isInsideReasoning = false

  mutating func consume(_ chunk: String) -> [AgentVisibleTextDelta] {
    pending += chunk
    var deltas: [AgentVisibleTextDelta] = []

    while pending.isEmpty == false {
      if isInsideReasoning {
        guard let closeTag = firstReasoningCloseTag(in: pending) else {
          appendReasoningDelta(pending, to: &deltas)
          pending.removeAll(keepingCapacity: true)
          return deltas
        }
        appendReasoningDelta(String(pending[..<closeTag.lowerBound]), to: &deltas)
        pending.removeSubrange(pending.startIndex..<closeTag.upperBound)
        isInsideReasoning = false
        continue
      }

      guard let openTag = firstReasoningOpenTag(in: pending) else {
        pending = retainedTagPrefixSuffix(in: pending, tagPrefixes: reasoningOpenTagPrefixes) ?? ""
        return deltas
      }
      pending.removeSubrange(pending.startIndex..<openTag.upperBound)
      isInsideReasoning = true
    }

    return deltas
  }

  private func appendReasoningDelta(_ text: String, to deltas: inout [AgentVisibleTextDelta]) {
    guard text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else { return }
    deltas.append(AgentVisibleTextDelta(text: text, isReasoning: true))
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
