import Foundation

public enum LocalAppActionKind: String, Codable, Hashable, Sendable {
  case chooseWorkingDirectory = "choose_working_directory"
  case confirmAgentContinuation = "confirm_agent_continuation"
}

public struct LocalAppActionRequest: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let sessionID: UUID
  public let action: LocalAppActionKind
  public let title: String
  public let message: String

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    action: LocalAppActionKind,
    title: String,
    message: String
  ) {
    self.id = id
    self.sessionID = sessionID
    self.action = action
    self.title = title
    self.message = message
  }
}

public enum LocalAppActionOutcome: Hashable, Sendable {
  case selectedURL(URL)
  case confirmation(Bool)
}

public struct LocalAppActionResponse: Hashable, Sendable {
  public let requestID: UUID
  public let outcome: LocalAppActionOutcome

  public init(requestID: UUID, outcome: LocalAppActionOutcome) {
    self.requestID = requestID
    self.outcome = outcome
  }
}

public protocol AgentLocalAppInteracting: Sendable {
  func perform(_ request: LocalAppActionRequest) async throws -> LocalAppActionResponse
}

public protocol AgentBuiltinToolProviding: Sendable {
  func descriptors() async -> [CapabilityDescriptor]
  func invoke(
    _ request: CapabilityInvocationRequest, catalog: AgentToolCatalog,
    currentSession: ConversationSession
  ) async throws -> CapabilityExecutionTrace
}
public protocol AgentInstructionSkillProviding: Sendable {
  func context(for task: String, sessionID: UUID) async throws -> InstructionSkillContext
  func deactivate(sessionID: UUID) async
}
public protocol AgentRegisteredAppProviding: Sendable {
  func listApps() async throws -> [RegisteredAppRecord]
  func loadApp(id: UUID) async throws -> RegisteredAppRecord
}
