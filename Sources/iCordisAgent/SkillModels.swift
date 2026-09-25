import Foundation
import iCordisKernel

public struct SkillDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var summary: String
  public var schema: CapabilityParameterSchema
  public var metadata: [String: JSONValue]
  public var isEnabled: Bool

  public init(
    id: String, name: String, summary: String, schema: CapabilityParameterSchema,
    metadata: [String: JSONValue], isEnabled: Bool
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.schema = schema
    self.metadata = metadata
    self.isEnabled = isEnabled
  }
}

public struct SkillInvocationRequest: Codable, Hashable, Sendable {
  public var skillID: String
  public var arguments: [String: JSONValue]

  public init(skillID: String, arguments: [String: JSONValue]) {
    self.skillID = skillID
    self.arguments = arguments
  }
}

public struct SkillInvocationResult: Codable, Hashable, Sendable {
  public var output: [ContentPart]
  public var raw: JSONValue?

  public init(output: [ContentPart], raw: JSONValue? = nil) {
    self.output = output
    self.raw = raw
  }
}

public struct LocalSkillManifest: Codable, Hashable, Sendable {
  public var id: String
  public var name: String
  public var summary: String
  public var language: String
  public var entrypoint: String
  public var schema: CapabilityParameterSchema
  public var metadata: [String: JSONValue]
  public var isEnabled: Bool
  public var timeoutSeconds: TimeInterval

  public init(
    id: String, name: String, summary: String, language: String, entrypoint: String,
    schema: CapabilityParameterSchema, metadata: [String: JSONValue], isEnabled: Bool,
    timeoutSeconds: TimeInterval
  ) {
    self.id = id
    self.name = name
    self.summary = summary
    self.language = language
    self.entrypoint = entrypoint
    self.schema = schema
    self.metadata = metadata
    self.isEnabled = isEnabled
    self.timeoutSeconds = timeoutSeconds
  }
}

public protocol SkillProviderProtocol: Sendable {
  func discoverSkills() async throws -> [SkillDescriptor]
  func invoke(_ request: SkillInvocationRequest) async throws -> SkillInvocationResult
}
