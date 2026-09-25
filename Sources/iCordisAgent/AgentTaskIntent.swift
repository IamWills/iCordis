import Foundation
import iCordisKernel

public enum AgentTaskRelationship: String, Codable, CaseIterable, Sendable, Hashable {
  case newTask = "new_task"
  case resumeRun = "resume_run"
}

public enum AgentTaskKind: String, Codable, CaseIterable, Sendable, Hashable {
  case general
  case pluginDevelopment = "plugin_development"
  case pluginInvocation = "plugin_invocation"
}

public enum AgentExecutionMode: String, Codable, CaseIterable, Sendable, Hashable {
  case directResponse = "direct_response"
  case agent
}

public enum AgentWebContentMode: String, Codable, CaseIterable, Sendable, Hashable {
  case standard
  case extracted
}

/// A model-resolved, structured interpretation of the user's request.
/// Runtime policy consumes only typed fields and validated run identifiers.
public struct AgentTaskIntent: Sendable, Hashable {
  public let currentRequest: String
  public let objective: String
  public let relationship: AgentTaskRelationship
  public let kind: AgentTaskKind
  public let executionMode: AgentExecutionMode
  public let webContentMode: AgentWebContentMode
  public let relatedRunID: UUID?

  public init(
    currentRequest: String,
    objective: String,
    relationship: AgentTaskRelationship,
    kind: AgentTaskKind,
    executionMode: AgentExecutionMode = .agent,
    webContentMode: AgentWebContentMode = .standard,
    relatedRunID: UUID? = nil
  ) {
    self.currentRequest = currentRequest
    self.objective = objective
    self.relationship = relationship
    self.kind = kind
    self.executionMode = executionMode
    self.webContentMode = webContentMode
    self.relatedRunID = relatedRunID
  }

  public static func newTask(_ request: String) -> AgentTaskIntent {
    AgentTaskIntent(
      currentRequest: request,
      objective: request,
      relationship: .newTask,
      kind: .general,
      executionMode: .agent
    )
  }

  public var requiresPluginDevelopmentEvidence: Bool { kind == .pluginDevelopment }
  public var requiresPluginInvocationEvidence: Bool { kind == .pluginInvocation }
  public var prefersExtractedWebContent: Bool { webContentMode == .extracted }
}

public struct AgentRunIntentCandidate: Codable, Sendable, Hashable {
  public let runID: UUID
  public let objective: String
  public let completionStatus: String
  public let unmetRequirements: [String]

  public static func recent(from session: ConversationSession, limit: Int = 8)
    -> [AgentRunIntentCandidate]
  {
    session.traces
      .filter { $0.request.capabilityID == "agent.run" }
      .sorted { $0.finishedAt > $1.finishedAt }
      .prefix(limit)
      .map { trace in
        let payload = trace.result.rawPayload?.pluginObjectValue
        return AgentRunIntentCandidate(
          runID: trace.id,
          objective: payload?["task"]?.stringValue
            ?? trace.request.arguments["task"]?.stringValue
            ?? "",
          completionStatus: payload?["completionStatus"]?.stringValue
            ?? (trace.result.success ? "completed" : "incomplete"),
          unmetRequirements: payload?["unmetRequirements"]?.pluginArrayValue?
            .compactMap(\.stringValue) ?? []
        )
      }
  }

  public init(runID: UUID, objective: String, completionStatus: String, unmetRequirements: [String])
  {
    self.runID = runID
    self.objective = objective
    self.completionStatus = completionStatus
    self.unmetRequirements = unmetRequirements
  }
}

public struct AgentTaskIntentParser: Sendable {
  private struct Payload: Decodable {
    let relationship: AgentTaskRelationship
    let taskKind: AgentTaskKind
    let executionMode: AgentExecutionMode
    let webContentMode: AgentWebContentMode
    let objective: String
    let relatedRunID: String

    enum CodingKeys: String, CodingKey {
      case relationship
      case taskKind = "task_kind"
      case executionMode = "execution_mode"
      case webContentMode = "web_content_mode"
      case objective
      case relatedRunID = "related_run_id"
    }
  }

  public func parse(
    _ output: String,
    currentRequest: String,
    candidates: [AgentRunIntentCandidate]
  ) throws -> AgentTaskIntent {
    guard let data = output.data(using: .utf8),
      let payload = try? JSONDecoder().decode(Payload.self, from: data)
    else {
      throw AgentError.invalidAction("expected a structured semantic task intent")
    }
    let objective = payload.objective.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !objective.isEmpty else {
      throw AgentError.invalidAction("semantic task objective is empty")
    }
    guard
      payload.executionMode == .agent
        || (payload.taskKind == .general && payload.webContentMode == .standard)
    else {
      throw AgentError.invalidAction(
        "a tool-dependent semantic task cannot use direct response mode")
    }

    let relatedRunID: UUID?
    switch payload.relationship {
    case .newTask:
      guard payload.relatedRunID.isEmpty else {
        throw AgentError.invalidAction("a new task cannot reference an earlier run")
      }
      relatedRunID = nil
    case .resumeRun:
      guard let parsedID = UUID(uuidString: payload.relatedRunID),
        candidates.contains(where: { $0.runID == parsedID })
      else {
        throw AgentError.invalidAction("the semantic task intent references an unknown run")
      }
      relatedRunID = parsedID
    }

    return AgentTaskIntent(
      currentRequest: currentRequest,
      objective: objective,
      relationship: payload.relationship,
      kind: payload.taskKind,
      executionMode: payload.executionMode,
      webContentMode: payload.webContentMode,
      relatedRunID: relatedRunID
    )
  }

  public init() {}
}
