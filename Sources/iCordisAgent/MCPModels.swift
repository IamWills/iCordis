import Foundation
import iCordisKernel

public struct MCPServerDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var transport: String
  public var endpoint: String?
  public var capabilities: [String]
  public var isEnabled: Bool

  public init(
    id: String, name: String, transport: String, endpoint: String? = nil, capabilities: [String],
    isEnabled: Bool
  ) {
    self.id = id
    self.name = name
    self.transport = transport
    self.endpoint = endpoint
    self.capabilities = capabilities
    self.isEnabled = isEnabled
  }
}

public struct MCPToolDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var serverID: String
  public var name: String
  public var description: String
  public var schema: CapabilityParameterSchema

  public init(
    id: String, serverID: String, name: String, description: String,
    schema: CapabilityParameterSchema
  ) {
    self.id = id
    self.serverID = serverID
    self.name = name
    self.description = description
    self.schema = schema
  }
}

public struct MCPResourceDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var serverID: String
  public var uri: String
  public var summary: String

  public init(id: String, serverID: String, uri: String, summary: String) {
    self.id = id
    self.serverID = serverID
    self.uri = uri
    self.summary = summary
  }
}

public struct MCPPromptDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var serverID: String
  public var name: String
  public var summary: String

  public init(id: String, serverID: String, name: String, summary: String) {
    self.id = id
    self.serverID = serverID
    self.name = name
    self.summary = summary
  }
}

public struct MCPInvocationRequest: Codable, Hashable, Sendable {
  public var serverID: String
  public var toolID: String
  public var arguments: [String: JSONValue]
  public var timeout: TimeInterval?

  public init(
    serverID: String, toolID: String, arguments: [String: JSONValue], timeout: TimeInterval? = nil
  ) {
    self.serverID = serverID
    self.toolID = toolID
    self.arguments = arguments
    self.timeout = timeout
  }
}

public struct MCPInvocationResult: Codable, Hashable, Sendable {
  public var output: [ContentPart]
  public var raw: JSONValue?

  public init(output: [ContentPart], raw: JSONValue? = nil) {
    self.output = output
    self.raw = raw
  }
}

public protocol MCPClientProtocol: Sendable {
  func discoverServers() async throws -> [MCPServerDescriptor]
  func discoverTools() async throws -> [MCPToolDescriptor]
  func invoke(_ request: MCPInvocationRequest) async throws -> MCPInvocationResult
}
