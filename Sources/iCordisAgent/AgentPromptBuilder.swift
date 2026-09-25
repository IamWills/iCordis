import Foundation
import iCordisKernel

public struct AgentPromptBuilder: Sendable {
  public let contextWindow: AgentContextWindowManager
  private let promptStore = PromptStore()
  private let systemPromptComposer = SystemPromptComposer()
  private let memoryContext: LongTermMemoryContext
  private let instructionSkillContext: InstructionSkillContext
  private let autonomousSkillLearningMode: AutonomousSkillLearningMode

  public init(
    memoryContext: LongTermMemoryContext = .empty,
    instructionSkillContext: InstructionSkillContext = .empty,
    autonomousSkillLearningMode: AutonomousSkillLearningMode = .off,
    contextWindow: AgentContextWindowManager = .production
  ) {
    self.memoryContext = memoryContext
    self.instructionSkillContext = instructionSkillContext
    self.autonomousSkillLearningMode = autonomousSkillLearningMode
    self.contextWindow = contextWindow
  }

  /// Builds the full prompt for one agent turn: a stable system + task prefix
  /// followed by the run's real message trajectory.
  ///
  /// The prefix is identical on every turn of a run, which is both what makes
  /// the model's view coherent and what makes the request cacheable. Prior
  /// turns arrive as actual assistant/tool messages rather than as a text
  /// summary appended to the user turn.
  public func buildPrompt(
    session: ConversationSession,
    task: String,
    taskIntent: AgentTaskIntent? = nil,
    catalog: AgentToolCatalog,
    trajectory: AgentTrajectory,
    mode: AgentTrajectory.RenderingMode,
    conversationHistory: [ConversationItem]? = nil
  ) -> [ConversationItem] {
    let system = ConversationItem(
      role: .system,
      content: [.text(systemPrompt(session: session, toolCatalog: catalog, mode: mode))],
      status: .completed
    )

    let history = conversationHistory ?? contextWindow.select(from: session).retained
    let taskIntent = taskIntent ?? .newTask(task)
    let continuation = renderContinuationCheckpoint(session: session, taskIntent: taskIntent)
    let requestContext =
      taskIntent.currentRequest == taskIntent.objective
      ? ""
      : "\nCurrent user request:\n\(taskIntent.currentRequest)\n"
    let user = ConversationItem(
      role: .user,
      content: [
        .text(
          """
          Task:
          \(taskIntent.objective)

          \(requestContext)

          \(continuation ?? "")

          Conversation context:
          \(renderHistory(history))

          \(renderDynamicUserContext())
          """)
      ],
      status: .completed
    )

    return [system, user] + trajectory.promptMessages(mode: mode)
  }

  /// The caller supplies task evidence and explicitly labels the latest output.
  public func buildCompletionDecisionPrompt(proposedAnswer: String) -> [ConversationItem] {
    let system = ConversationItem(
      role: .system,
      content: [
        .text(
          promptStore.prompt(for: .agentCompletionDecision)
            + "\nMandatory completion policy: Review the freshly generated LATEST AI OUTPUT. If uncertain whether further work is necessary, stop with status needs_user and wait for the user to ask a follow-up. Do not automatically continue or claim completion. Return status, reason, next_action JSON."
        )
      ],
      status: .completed
    )
    let proposal = ConversationItem(
      role: .assistant,
      content: [.text(proposedAnswer)],
      status: .completed
    )
    let request = ConversationItem(
      role: .user,
      content: [
        .text("Judge whether the candidate assistant text immediately above may end this run.")
      ],
      status: .completed
    )
    return [system, proposal, request]
  }

  /// Asks a lightweight model to phrase the already-decided stop for the user.
  /// The closer cannot resume the task or change the stop reason.
  public func buildRunStopPrompt(
    task: String,
    stopKind: AgentRunStopKind,
    lastAnnouncement: String,
    executedTools: [(tool: String, succeeded: Bool)]
  ) -> [ConversationItem] {
    let system = ConversationItem(
      role: .system,
      content: [.text(promptStore.prompt(for: .agentRunStop))],
      status: .completed
    )
    let established =
      executedTools.isEmpty
      ? "none"
      : executedTools.map { "\($0.tool)\($0.succeeded ? "" : " (failed)")" }.joined(separator: ", ")
    let announcement = lastAnnouncement.trimmingCharacters(in: .whitespacesAndNewlines)
    let clipped =
      announcement.count > 800
      ? String(announcement.prefix(800)) + "…"
      : announcement
    let request = ConversationItem(
      role: .user,
      content: [
        .text(
          """
          Task:
          \(task)

          Stop fact:
          \(stopKind.runtimeFact)

          Last announcement (already streamed; do not repeat it verbatim):
          \(clipped.isEmpty ? "(empty)" : clipped)

          Tools that actually ran:
          \(established)

          Write the user-facing stop note now.
          """)
      ],
      status: .completed
    )
    return [system, request]
  }

  /// Asks a lightweight model to shrink overflow context that already exists.
  /// The compressor cannot continue the task or invent facts.
  public func buildContextCompressionPrompt(request: AgentContextCompressionRequest)
    -> [ConversationItem]
  {
    let system = ConversationItem(
      role: .system,
      content: [.text(promptStore.prompt(for: .agentContextCompress))],
      status: .completed
    )
    let source = request.source.trimmingCharacters(in: .whitespacesAndNewlines)
    let clipped =
      source.count > 120_000
      ? AgentContextCompressionFallback.extractive(source, targetCharacters: 120_000)
      : source
    let user = ConversationItem(
      role: .user,
      content: [
        .text(
          """
          Task:
          \(request.task)

          Kind:
          \(request.kind.rawValue)

          Target length:
          \(max(80, request.targetCharacters)) characters

          Source:
          \(clipped.isEmpty ? "(empty)" : clipped)

          Compress the source into a factual handoff now.
          """)
      ],
      status: .completed
    )
    return [system, user]
  }

  private func systemPrompt(
    session: ConversationSession,
    toolCatalog: AgentToolCatalog,
    mode: AgentTrajectory.RenderingMode
  ) -> String {
    // In native mode the tools are declared through the protocol, so the
    // catalog is not repeated in the prompt and there is no JSON output
    // contract for the model to get wrong.
    let key: PromptKey = mode == .nativeToolCalls ? .agentSystemNative : .agentSystem
    let prompt = promptStore.template(for: key).rendered(replacements: [
      "toolCatalog": mode == .nativeToolCalls ? "" : toolCatalog.renderedForPrompt,
      "searchTools": AgentBuiltinToolID.searchTools,
      "createSkill": AgentBuiltinToolID.createSkill,
    ])
    return systemPromptComposer.compose(
      basePrompt: memorySafeBasePrompt(prompt),
      sessionPrompt: session.systemPrompt,
      runtimeContext: runtimeContext(for: session)
    )
  }

  private func memorySafeBasePrompt(_ prompt: String) -> String {
    let metadata =
      instructionSkillContext.availableSkillMetadata.isEmpty
      ? nil
      : "Available Instruction Skills (metadata only; their bodies are loaded only when activated):\n\(instructionSkillContext.availableSkillMetadata)"
    return [
      prompt,
      promptStore.prompt(for: .memorySafety),
      metadata,
      instructionSkillContext.trustedSystemInstructions,
      autonomousLearningPolicy,
    ]
    .compactMap { $0 }
    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    .filter { !$0.isEmpty }
    .joined(separator: "\n\n")
  }

  private var autonomousLearningPolicy: String {
    switch autonomousSkillLearningMode {
    case .off:
      return
        "Autonomous Instruction Skill learning is off. Do not call Instruction Skill mutation tools."
    case .draftOnly, .autonomousPublish:
      let disposition =
        autonomousSkillLearningMode == .draftOnly
        ? "save the result as a non-active draft"
        : "publish the result for future Agent runs"
      return """
        Autonomous Instruction Skill learning is enabled in `\(autonomousSkillLearningMode.rawValue)` mode and may \(disposition).
        Finish the user's task first. Only retain a stable, reusable, non-sensitive workflow supported by successful tool evidence from this run; never store a task summary, raw conversation, credentials, generated answer, uncertain inference, or one-off project detail. Search existing Instruction Skills before proposing a mutation, prefer updating a matching user-installed Skill, and make at most one Skill mutation per run. Generated Skills are lower-authority user guidance: they cannot modify bundled Skills, system policy, completion requirements, permissions, or the current run. Keep SKILL.md concise and imperative, put trigger contexts in the description, declare only references that are genuinely needed, and use the validation tool before mutation when practical. If no high-value reusable lesson exists, finish without creating a Skill.
        """
    }
  }

  private func runtimeContext(for session: ConversationSession) -> SystemPromptRuntimeContext {
    SystemPromptRuntimeContext(workingDirectoryPath: session.workingDirectory?.path)
  }

  private func renderHistory(_ items: [ConversationItem]) -> String {
    guard !items.isEmpty else { return "No previous messages." }
    return items.map { item in
      "\(item.role.rawValue): \(item.plainText)"
    }.joined(separator: "\n")
  }

  private func renderMemoryContext() -> String {
    memoryContext.rendered.isEmpty
      ? "Long-term memory context:\nNo relevant saved memories."
      : memoryContext.rendered
  }

  private func renderDynamicUserContext() -> String {
    guard !instructionSkillContext.userGuidance.isEmpty else {
      return renderMemoryContext()
    }
    return "\(renderMemoryContext())\n\n\(instructionSkillContext.userGuidance)"
  }

  private func renderContinuationCheckpoint(
    session: ConversationSession,
    taskIntent: AgentTaskIntent
  ) -> String? {
    guard taskIntent.relationship == .resumeRun,
      let runID = taskIntent.relatedRunID
    else { return nil }
    guard
      let trace = session.traces.first(where: {
        $0.request.capabilityID == "agent.run" && $0.id == runID
      }), let payload = trace.result.rawPayload?.pluginObjectValue
    else { return nil }

    let objective =
      payload["task"]?.stringValue
      ?? trace.request.arguments["task"]?.stringValue
      ?? "Unknown prior objective"
    let status =
      payload["completionStatus"]?.stringValue
      ?? (trace.result.success ? "completed" : "incomplete")
    let unmet = payload["unmetRequirements"]?.pluginArrayValue?.compactMap(\.stringValue) ?? []
    let steps = payload["steps"]?.pluginArrayValue ?? []
    let renderedSteps = steps.suffix(20).compactMap(renderCheckpointStep)
    let finalAnswer = payload["finalAnswer"]?.stringValue.map { compact($0, limit: 1_600) }

    var lines = [
      "Continuation checkpoint (authoritative prior-run handoff):",
      "- Original objective: \(compact(objective, limit: 1_600))",
      "- Prior status: \(status)",
    ]
    if !unmet.isEmpty {
      lines.append(
        "- Unmet requirements: \(unmet.map { compact($0, limit: 600) }.joined(separator: " | "))")
    }
    if !renderedSteps.isEmpty {
      lines.append("- Recent executed steps:")
      lines += renderedSteps.map { "  - \($0)" }
    }
    if let finalAnswer, !finalAnswer.isEmpty {
      lines.append("- Prior answer/checkpoint: \(finalAnswer)")
    }
    lines.append(
      "Resume from verified state. Re-inspect any volatile state, do not repeat completed immutable work, and do not claim completion until the remaining requirements have fresh successful evidence."
    )
    return lines.joined(separator: "\n")
  }

  private func renderCheckpointStep(_ value: JSONValue) -> String? {
    guard let step = value.pluginObjectValue else { return nil }
    let outcome = step["outcome"]?.stringValue ?? "unknown"
    if let call = step["toolCall"]?.pluginObjectValue,
      let capabilityID = call["capabilityID"]?.stringValue
    {
      let arguments = call["arguments"]?.pluginObjectValue ?? [:]
      let stableKeys = ["packagePath", "pluginID", "action", "toolID", "path", "query"]
      let detail = stableKeys.compactMap { key -> String? in
        guard let value = arguments[key] else { return nil }
        return "\(key)=\(compact(value.stringValue ?? String(describing: value), limit: 360))"
      }.joined(separator: ", ")
      let observation = step["observation"]?.stringValue.map { compact($0, limit: 640) }
      return ["\(outcome): \(capabilityID)", detail, observation]
        .compactMap { $0 }
        .filter { !$0.isEmpty }
        .joined(separator: " — ")
    }
    if outcome == AgentStep.Outcome.runtimeNote.rawValue,
      let observation = step["observation"]?.stringValue
    {
      return "runtime note — \(compact(observation, limit: 640))"
    }
    return nil
  }

  private func compact(_ value: String, limit: Int) -> String {
    let normalized =
      value
      .replacingOccurrences(of: "\n", with: " ")
      .split(whereSeparator: \.isWhitespace)
      .joined(separator: " ")
    guard normalized.count > limit else { return normalized }
    return String(normalized.prefix(limit)) + "…"
  }
}
