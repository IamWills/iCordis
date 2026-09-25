import Foundation
import iCordisKernel

public enum ChatRole: String, Codable, CaseIterable, Sendable {
  case system
  case user
  case assistant
  case tool
}

public enum MessageStatus: String, Codable, CaseIterable, Sendable {
  case pending
  case streaming
  case completed
  case cancelled
  case failed
}

public enum OutputProtocolPreference: String, Codable, CaseIterable, Sendable {
  case responses
  case chatCompletions
}

public struct Usage: Codable, Hashable, Sendable {
  public var inputTokens: Int
  public var outputTokens: Int
  public var totalTokens: Int
  public var tokensPerSecond: Double?

  public static let zero = Usage(
    inputTokens: 0, outputTokens: 0, totalTokens: 0, tokensPerSecond: nil)

  public init(inputTokens: Int, outputTokens: Int, totalTokens: Int, tokensPerSecond: Double? = nil)
  {
    self.inputTokens = inputTokens
    self.outputTokens = outputTokens
    self.totalTokens = totalTokens
    self.tokensPerSecond = tokensPerSecond
  }
}

public struct ContentPart: Codable, Hashable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case text
    case code
    case structured
    case capabilityReference
    case imageFile
    case audioFile
    case videoFile
  }

  public var id: UUID
  public var kind: Kind
  public var text: String?
  public var payload: JSONValue?
  public var mimeType: String?
  public var uri: String?
  public var displayName: String?

  public init(
    id: UUID = UUID(),
    kind: Kind = .text,
    text: String? = nil,
    payload: JSONValue? = nil,
    mimeType: String? = nil,
    uri: String? = nil,
    displayName: String? = nil
  ) {
    self.id = id
    self.kind = kind
    self.text = text
    self.payload = payload
    self.mimeType = mimeType
    self.uri = uri
    self.displayName = displayName
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
    kind = try container.decodeIfPresent(Kind.self, forKey: .kind) ?? .text
    text = try container.decodeIfPresent(String.self, forKey: .text)
    payload = try container.decodeIfPresent(JSONValue.self, forKey: .payload)
    mimeType = try container.decodeIfPresent(String.self, forKey: .mimeType)
    uri = try container.decodeIfPresent(String.self, forKey: .uri)
    displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
  }

  public var contextTokenEstimate: Int {
    switch kind {
    case .text, .code:
      return max(1, (text ?? "").count / 4)
    case .structured, .capabilityReference:
      return 48
    case .imageFile, .videoFile:
      return 256
    case .audioFile:
      return 512
    }
  }

  public var fileURL: URL? {
    guard let uri else { return nil }
    if let parsed = URL(string: uri), let scheme = parsed.scheme {
      guard scheme == "file" else { return nil }
      return parsed
    }
    if uri.hasPrefix("file://"), let url = URL(string: uri) {
      return url
    }
    return URL(fileURLWithPath: uri)
  }
}

extension ContentPart {
  public static func text(_ text: String) -> ContentPart {
    ContentPart(kind: .text, text: text)
  }

  public static func imageFile(url: URL, displayName: String? = nil, mimeType: String? = nil)
    -> ContentPart
  {
    ContentPart(
      kind: .imageFile,
      text: nil,
      payload: nil,
      mimeType: mimeType,
      uri: url.isFileURL ? url.path : url.absoluteString,
      displayName: displayName ?? url.lastPathComponent
    )
  }

  public static func audioFile(url: URL, displayName: String? = nil, mimeType: String? = nil)
    -> ContentPart
  {
    ContentPart(
      kind: .audioFile,
      text: nil,
      payload: nil,
      mimeType: mimeType,
      uri: url.isFileURL ? url.path : url.absoluteString,
      displayName: displayName ?? url.lastPathComponent
    )
  }

  public static func videoFile(url: URL, displayName: String? = nil, mimeType: String? = nil)
    -> ContentPart
  {
    ContentPart(
      kind: .videoFile,
      text: nil,
      payload: nil,
      mimeType: mimeType,
      uri: url.isFileURL ? url.path : url.absoluteString,
      displayName: displayName ?? url.lastPathComponent
    )
  }
}

public struct OutputItem: Codable, Hashable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case message
    case toolCall
    case toolResult
    case reasoning
    case metadata
  }

  public var id: UUID
  public var kind: Kind
  public var role: ChatRole?
  public var content: [ContentPart]
  public var name: String?
  public var payload: JSONValue?

  public init(
    id: UUID = UUID(),
    kind: Kind,
    role: ChatRole? = nil,
    content: [ContentPart] = [],
    name: String? = nil,
    payload: JSONValue? = nil
  ) {
    self.id = id
    self.kind = kind
    self.role = role
    self.content = content
    self.name = name
    self.payload = payload
  }
}

public struct AIRequest: Codable, Hashable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var modelID: UUID
  public var outputPreference: OutputProtocolPreference
  public var messages: [ConversationItem]
  public var parameters: InferenceParameters
  public var capabilityDescriptors: [CapabilityDescriptor]
  public var structuredOutputSchema: JSONValue?
  public var protocolMetadata: [String: JSONValue]

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    modelID: UUID,
    outputPreference: OutputProtocolPreference,
    messages: [ConversationItem],
    parameters: InferenceParameters,
    capabilityDescriptors: [CapabilityDescriptor],
    structuredOutputSchema: JSONValue? = nil,
    protocolMetadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.sessionID = sessionID
    self.modelID = modelID
    self.outputPreference = outputPreference
    self.messages = messages
    self.parameters = parameters
    self.capabilityDescriptors = capabilityDescriptors
    self.structuredOutputSchema = structuredOutputSchema
    self.protocolMetadata = protocolMetadata
  }
}

public struct AIResponse: Codable, Hashable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var modelID: UUID
  public var output: [OutputItem]
  public var usage: Usage
  public var createdAt: Date
  public var metadata: [String: JSONValue]

  public init(
    id: UUID, sessionID: UUID, modelID: UUID, output: [OutputItem], usage: Usage, createdAt: Date,
    metadata: [String: JSONValue]
  ) {
    self.id = id
    self.sessionID = sessionID
    self.modelID = modelID
    self.output = output
    self.usage = usage
    self.createdAt = createdAt
    self.metadata = metadata
  }
}

public enum StreamEvent: Sendable, Hashable {
  case responseEvent(ResponseStreamEvent)
  case started(responseID: UUID, timestamp: Date)
  case textDelta(messageID: UUID, delta: String)
  case capabilityInvocationStarted(CapabilityInvocationProgress)
  case capabilityInvocation(CapabilityExecutionTrace)
  case usage(Usage)
  case completed(messageID: UUID, finishedAt: Date)
  case failed(messageID: UUID?, description: String)
}
