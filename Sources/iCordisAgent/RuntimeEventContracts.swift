import Foundation
import iCordisKernel

public struct RuntimeEventMetadata: Codable, Hashable, Sendable {
  public let eventID: UUID
  public let runID: UUID?
  public let sessionID: UUID?
  public let pluginID: PluginID
  public let timestamp: Date

  public init(
    eventID: UUID = UUID(),
    runID: UUID? = nil,
    sessionID: UUID? = nil,
    pluginID: PluginID,
    timestamp: Date = .now
  ) {
    self.eventID = eventID
    self.runID = runID
    self.sessionID = sessionID
    self.pluginID = pluginID
    self.timestamp = timestamp
  }
}

public struct AgentStepEvent: Sendable {
  public let metadata: RuntimeEventMetadata
  public let step: Int
  public let request: AgentLoopRequest

  public init(metadata: RuntimeEventMetadata, step: Int, request: AgentLoopRequest) {
    self.metadata = metadata
    self.step = step
    self.request = request
  }
}

public enum AgentTurnDecision: String, Codable, Sendable {
  case continueRun
  case stop
}

public struct ModelStreamEvent: Sendable {
  public let metadata: RuntimeEventMetadata
  public let event: StreamEvent

  public init(metadata: RuntimeEventMetadata, event: StreamEvent) {
    self.metadata = metadata
    self.event = event
  }
}

public struct SessionCheckpoint: Codable, Hashable, Sendable {
  public let pluginID: PluginID
  public let persistedEventCount: Int

  public init(pluginID: PluginID, persistedEventCount: Int) {
    self.pluginID = pluginID
    self.persistedEventCount = persistedEventCount
  }
}

public enum RuntimeEvents {
  public static let agentPreStep = MiddlewareEvent<AgentStepEvent, AgentStepEvent>(
    EventID("agent/pre-step"))
  public static let agentRequest = MiddlewareEvent<AgentLoopRequest, AgentLoopRequest>(
    EventID("agent/request"))
  public static let agentTurnStopping = SerialEvent<AgentStepEvent, AgentTurnDecision>(
    EventID("agent/turn-stopping"))
  public static let agentStatus = NotificationEvent<RuntimeObservation>(EventID("agent/status"))

  public static let modelRequest = MiddlewareEvent<AIRequest, AIRequest>(EventID("model/request"))
  public static let modelStream = NotificationEvent<ModelStreamEvent>(EventID("model/stream"))

  public static let toolsPreExecute = MiddlewareEvent<
    CapabilityInvocationRequest, CapabilityInvocationRequest
  >(EventID("tools/pre-execute"))
  public static let toolsExecute = MiddlewareEvent<
    CapabilityInvocationRequest, CapabilityExecutionTrace
  >(EventID("tools/execute"))
  public static let toolsPostExecute = NotificationEvent<CapabilityExecutionTrace>(
    EventID("tools/post-execute"))

  public static let sessionEvent = NotificationEvent<RuntimeSessionEvent>(EventID("session/event"))
  public static let sessionFlush = ParallelEvent<RuntimeEventMetadata, SessionCheckpoint>(
    EventID("session/flush"))

  public static let contextAssemble = TransformEvent<[ContextContribution]>(
    EventID("context/assemble"))
  public static let systemPromptAssemble = TransformEvent<[PromptFragment]>(
    EventID("system-prompt/assemble"))
  public static let memoryChanged = NotificationEvent<RuntimeEventMetadata>(
    EventID("memory/changed"))
  public static let approvalRequest = MiddlewareEvent<
    BusinessApprovalRequest, BusinessApprovalDecision
  >(EventID("approval/request"))
  public static let transactionAuthorize = MiddlewareEvent<
    TransactionAuthorizationRequest, BusinessApprovalDecision
  >(EventID("transaction/authorize"))
}
