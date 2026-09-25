import Foundation
import iCordisKernel

public struct ResponseConversationEventRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var conversationID: String
  public var sessionID: UUID
  public var modelID: UUID?
  public var responseID: String?
  public var sequence: Int
  public var event: ResponseStreamEvent
  public var createdAt: Date

  public init(
    id: UUID = UUID(),
    conversationID: String,
    sessionID: UUID,
    modelID: UUID?,
    responseID: String?,
    sequence: Int,
    event: ResponseStreamEvent,
    createdAt: Date = .now
  ) {
    self.id = id
    self.conversationID = conversationID
    self.sessionID = sessionID
    self.modelID = modelID
    self.responseID = responseID
    self.sequence = sequence
    self.event = event
    self.createdAt = createdAt
  }
}

public enum ResponsesAIOutputSpec {
  public static let protocolName = "zyw/responses"
  public static let conversationIDMetadataKey = "responses.conversation_id"
  public static let responseIDMetadataKey = "responses.response_id"

  public static func makeConversationID(sessionID: UUID) -> String {
    "conv_\(sessionID.uuidString.lowercased())"
  }

  public static func responseID(_ id: UUID) -> String {
    prefixed(id.uuidString, prefix: "resp")
  }

  public static func messageID(_ id: UUID) -> String {
    prefixed(id.uuidString, prefix: "msg")
  }

  public static func functionCallID(_ id: UUID) -> String {
    prefixed(id.uuidString, prefix: "fc")
  }

  public static func callID(_ id: UUID) -> String {
    prefixed(id.uuidString, prefix: "call")
  }

  public static func prefixed(_ id: String, prefix: String) -> String {
    id.hasPrefix("\(prefix)_") ? id : "\(prefix)_\(id)"
  }

  public static func eventWithConversationID(_ event: ResponseStreamEvent, conversationID: String)
    -> ResponseStreamEvent
  {
    guard event.conversationID != conversationID else { return event }
    var copy = event
    copy.conversationID = conversationID
    return copy
  }

  public static func requestWithConversationID(_ request: AIRequest, conversationID: String)
    -> AIRequest
  {
    var copy = request
    copy.protocolMetadata[conversationIDMetadataKey] = .string(conversationID)
    copy.protocolMetadata["responses.output_spec"] = .string(protocolName)
    return copy
  }
}
