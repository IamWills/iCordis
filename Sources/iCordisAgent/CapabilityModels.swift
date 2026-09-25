import Foundation
import iCordisKernel

public enum CapabilityKind: String, Codable, CaseIterable, Sendable {
  case mcpTool
  case skill
  case builtin
  case pluginTool
}

public struct CapabilityParameterSchema: Codable, Hashable, Sendable {
  public var type: String
  public var properties: [String: JSONValue]
  public var required: [String]

  public init(type: String, properties: [String: JSONValue], required: [String]) {
    self.type = type
    self.properties = properties
    self.required = required
  }
}

public struct CapabilityDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var kind: CapabilityKind
  public var name: String
  public var summary: String
  public var schema: CapabilityParameterSchema
  public var isEnabled: Bool
  public var metadata: [String: JSONValue]

  public init(
    id: String, kind: CapabilityKind, name: String, summary: String,
    schema: CapabilityParameterSchema, isEnabled: Bool, metadata: [String: JSONValue]
  ) {
    self.id = id
    self.kind = kind
    self.name = name
    self.summary = summary
    self.schema = schema
    self.isEnabled = isEnabled
    self.metadata = metadata
  }
}

public struct CapabilityInvocationRequest: Codable, Hashable, Sendable {
  public var sessionID: UUID
  public var capabilityID: String
  public var arguments: [String: JSONValue]
  public var initiatedBy: ChatRole
  public var timeout: TimeInterval?

  public init(
    sessionID: UUID, capabilityID: String, arguments: [String: JSONValue], initiatedBy: ChatRole,
    timeout: TimeInterval? = nil
  ) {
    self.sessionID = sessionID
    self.capabilityID = capabilityID
    self.arguments = arguments
    self.initiatedBy = initiatedBy
    self.timeout = timeout
  }
}

public struct CapabilityInvocationResult: Codable, Hashable, Sendable {
  public var capabilityID: String
  public var success: Bool
  public var content: [ContentPart]
  public var rawPayload: JSONValue?
  public var latency: TimeInterval

  public init(
    capabilityID: String, success: Bool, content: [ContentPart], rawPayload: JSONValue? = nil,
    latency: TimeInterval
  ) {
    self.capabilityID = capabilityID
    self.success = success
    self.content = content
    self.rawPayload = rawPayload
    self.latency = latency
  }
}

public struct CapabilityExecutionTrace: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var request: CapabilityInvocationRequest
  public var result: CapabilityInvocationResult
  public var startedAt: Date
  public var finishedAt: Date

  public init(
    id: UUID, request: CapabilityInvocationRequest, result: CapabilityInvocationResult,
    startedAt: Date, finishedAt: Date
  ) {
    self.id = id
    self.request = request
    self.result = result
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}

public struct CapabilityInvocationProgress: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var request: CapabilityInvocationRequest
  public var startedAt: Date

  public init(id: UUID = UUID(), request: CapabilityInvocationRequest, startedAt: Date = .now) {
    self.id = id
    self.request = request
    self.startedAt = startedAt
  }
}
