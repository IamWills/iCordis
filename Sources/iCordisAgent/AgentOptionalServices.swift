import Foundation
import iCordisKernel

public struct AgentContinuationService: WilliamService {
  public let request: @Sendable (UUID, String) async -> Bool
  public init(request: @escaping @Sendable (UUID, String) async -> Bool) { self.request = request }
  public static let decline = Self { _, _ in false }
}
/// An optional host-owned script bridge. The SDK does not start servers or execute code.
public struct AgentToolBridgeService: WilliamService {
  public let open: @Sendable (AgentToolExecutor, UUID) async throws -> AgentToolBridgeLease
  public init(
    open: @escaping @Sendable (AgentToolExecutor, UUID) async throws -> AgentToolBridgeLease
  ) { self.open = open }
  public static let forbiddenTools: Set<String> = [
    AgentBuiltinToolID.runCode, AgentBuiltinToolID.activateToolGroup,
    AgentBuiltinToolID.searchTools,
  ]
}
public struct AgentToolBridgeLease: Sendable {
  public let arguments: [String: JSONValue]
  public let callRecords: @Sendable () async -> [AgentBridgeCallRecord]
  public let stop: @Sendable () async -> Void
  public init(
    arguments: [String: JSONValue], stop: @escaping @Sendable () async -> Void,
    callRecords: @escaping @Sendable () async -> [AgentBridgeCallRecord] = { [] }
  ) {
    self.arguments = arguments
    self.stop = stop
    self.callRecords = callRecords
  }
}

public struct AgentBridgeCallRecord: Sendable {
  public let tool: String
  public let succeeded: Bool
  public init(tool: String, succeeded: Bool) {
    self.tool = tool
    self.succeeded = succeeded
  }
}
