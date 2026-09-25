import Foundation
import iCordisKernel

public struct ResponseStreamEvent: Codable, Hashable, Sendable {
  public struct ResponsePayload: Codable, Hashable, Sendable {
    public var id: String
    public var object: String
    public var createdAt: Int?
    public var status: String?
    public var model: String?
    public var output: [OutputItemPayload]?
    public var usage: [String: JSONValue]?
    public var metadata: [String: JSONValue]?
    public var error: JSONValue?
    public var incompleteDetails: JSONValue?
    public var parallelToolCalls: Bool?
    public var toolChoice: JSONValue?
    public var tools: [JSONValue]?
    public var temperature: Double?
    public var topP: Double?
    public var truncation: String?
    public var text: JSONValue?

    public init(
      id: String,
      object: String = "response",
      createdAt: Int? = nil,
      status: String? = nil,
      model: String? = nil,
      output: [OutputItemPayload]? = nil,
      usage: [String: JSONValue]? = nil,
      metadata: [String: JSONValue]? = nil,
      error: JSONValue? = nil,
      incompleteDetails: JSONValue? = nil,
      parallelToolCalls: Bool? = nil,
      toolChoice: JSONValue? = nil,
      tools: [JSONValue]? = nil,
      temperature: Double? = nil,
      topP: Double? = nil,
      truncation: String? = nil,
      text: JSONValue? = nil
    ) {
      self.id = id
      self.object = object
      self.createdAt = createdAt
      self.status = status
      self.model = model
      self.output = output
      self.usage = usage
      self.metadata = metadata
      self.error = error
      self.incompleteDetails = incompleteDetails
      self.parallelToolCalls = parallelToolCalls
      self.toolChoice = toolChoice
      self.tools = tools
      self.temperature = temperature
      self.topP = topP
      self.truncation = truncation
      self.text = text
    }

    public enum CodingKeys: String, CodingKey {
      case id
      case object
      case createdAt = "created_at"
      case status
      case model
      case output
      case usage
      case metadata
      case error
      case incompleteDetails = "incomplete_details"
      case parallelToolCalls = "parallel_tool_calls"
      case toolChoice = "tool_choice"
      case tools
      case temperature
      case topP = "top_p"
      case truncation
      case text
    }
  }

  public struct OutputItemPayload: Codable, Hashable, Sendable {
    public var id: String?
    public var type: String
    public var status: String?
    public var role: String?
    public var name: String?
    public var callID: String?
    public var arguments: String?
    public var output: String?
    public var result: String?
    public var content: [ContentPartPayload]?

    public init(
      id: String? = nil,
      type: String,
      status: String? = nil,
      role: String? = nil,
      name: String? = nil,
      callID: String? = nil,
      arguments: String? = nil,
      output: String? = nil,
      result: String? = nil,
      content: [ContentPartPayload]? = nil
    ) {
      self.id = id
      self.type = type
      self.status = status
      self.role = role
      self.name = name
      self.callID = callID
      self.arguments = arguments
      self.output = output
      self.result = result
      self.content = content
    }

    public enum CodingKeys: String, CodingKey {
      case id
      case type
      case status
      case role
      case name
      case callID = "call_id"
      case arguments
      case output
      case result
      case content
    }
  }

  public struct ContentPartPayload: Codable, Hashable, Sendable {
    public var type: String
    public var text: String?
    public var imageURL: String?
    public var audioURL: String?
    public var videoURL: String?
    public var url: String?
    public var data: JSONValue?
    public var mimeType: String?
    public var annotations: [JSONValue]?

    public init(
      type: String,
      text: String? = nil,
      imageURL: String? = nil,
      audioURL: String? = nil,
      videoURL: String? = nil,
      url: String? = nil,
      data: JSONValue? = nil,
      mimeType: String? = nil,
      annotations: [JSONValue]? = nil
    ) {
      self.type = type
      self.text = text
      self.imageURL = imageURL
      self.audioURL = audioURL
      self.videoURL = videoURL
      self.url = url
      self.data = data
      self.mimeType = mimeType
      self.annotations = annotations
    }

    public enum CodingKeys: String, CodingKey {
      case type
      case text
      case imageURL = "image_url"
      case audioURL = "audio_url"
      case videoURL = "video_url"
      case url
      case data
      case mimeType = "mime_type"
      case annotations
    }
  }

  public var type: String
  public var responseID: String?
  public var itemID: String?
  public var outputIndex: Int?
  public var contentIndex: Int?
  public var delta: String?
  public var arguments: String?
  public var name: String?
  public var conversationID: String?
  public var item: OutputItemPayload?
  public var part: ContentPartPayload?
  public var response: ResponsePayload?
  public var error: JSONValue?
  public var code: String?
  public var message: String?
  public var param: JSONValue?
  public var sequenceNumber: Int?

  public init(
    type: String,
    responseID: String? = nil,
    itemID: String? = nil,
    outputIndex: Int? = nil,
    contentIndex: Int? = nil,
    delta: String? = nil,
    arguments: String? = nil,
    name: String? = nil,
    conversationID: String? = nil,
    item: OutputItemPayload? = nil,
    part: ContentPartPayload? = nil,
    response: ResponsePayload? = nil,
    error: JSONValue? = nil,
    code: String? = nil,
    message: String? = nil,
    param: JSONValue? = nil,
    sequenceNumber: Int? = nil
  ) {
    self.type = type
    self.responseID = responseID
    self.itemID = itemID
    self.outputIndex = outputIndex
    self.contentIndex = contentIndex
    self.delta = delta
    self.arguments = arguments
    self.name = name
    self.conversationID = conversationID
    self.item = item
    self.part = part
    self.response = response
    self.error = error
    self.code = code
    self.message = message
    self.param = param
    self.sequenceNumber = sequenceNumber
  }

  public enum CodingKeys: String, CodingKey {
    case type
    case responseID = "response_id"
    case itemID = "item_id"
    case outputIndex = "output_index"
    case contentIndex = "content_index"
    case delta
    case arguments
    case name
    case conversationID = "conversation_id"
    case item
    case part
    case response
    case error
    case code
    case message
    case param
    case sequenceNumber = "sequence_number"
  }
}

extension ResponseStreamEvent {
  public static func responseCreated(
    responseID: UUID, model: String? = nil, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    let responseID = ResponsesAIOutputSpec.responseID(responseID)
    return ResponseStreamEvent(
      type: "response.created",
      response: .init(
        id: responseID,
        object: "response",
        createdAt: Int(Date().timeIntervalSince1970),
        status: "queued",
        model: model,
        output: [],
        usage: nil,
        metadata: [:],
        error: .null,
        incompleteDetails: .null,
        parallelToolCalls: true,
        toolChoice: .string("auto"),
        tools: [],
        temperature: 1,
        topP: 1,
        truncation: "disabled",
        text: .object(["format": .object(["type": .string("text")])])
      ),
      sequenceNumber: sequenceNumber
    )
  }

  public static func responseQueued(
    responseID: UUID, model: String? = nil, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    let responseID = ResponsesAIOutputSpec.responseID(responseID)
    return ResponseStreamEvent(
      type: "response.queued",
      responseID: responseID,
      response: .init(
        id: responseID, object: "response", createdAt: nil, status: "queued", model: model),
      sequenceNumber: sequenceNumber
    )
  }

  public static func responseInProgress(
    responseID: UUID, model: String? = nil, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    let responseID = ResponsesAIOutputSpec.responseID(responseID)
    return ResponseStreamEvent(
      type: "response.in_progress",
      responseID: responseID,
      response: .init(
        id: responseID, object: "response", createdAt: nil, status: "in_progress", model: model),
      sequenceNumber: sequenceNumber
    )
  }

  public static func messageOutputItemAdded(
    responseID: UUID, messageID: UUID, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    let responseID = ResponsesAIOutputSpec.responseID(responseID)
    let messageID = ResponsesAIOutputSpec.messageID(messageID)
    return ResponseStreamEvent(
      type: "response.output_item.added",
      responseID: responseID,
      itemID: messageID,
      outputIndex: 0,
      item: .init(
        id: messageID,
        type: "message",
        status: "in_progress",
        role: "assistant",
        content: []
      ),
      sequenceNumber: sequenceNumber
    )
  }

  public static func contentPartAdded(responseID: UUID, messageID: UUID, sequenceNumber: Int? = nil)
    -> ResponseStreamEvent
  {
    let responseID = ResponsesAIOutputSpec.responseID(responseID)
    let messageID = ResponsesAIOutputSpec.messageID(messageID)
    return ResponseStreamEvent(
      type: "response.content_part.added",
      responseID: responseID,
      itemID: messageID,
      outputIndex: 0,
      contentIndex: 0,
      part: .init(type: "output_text", text: "", annotations: []),
      sequenceNumber: sequenceNumber
    )
  }

  public static func outputTextDelta(
    responseID: UUID, messageID: UUID, delta: String, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    ResponseStreamEvent(
      type: "response.output_text.delta",
      responseID: ResponsesAIOutputSpec.responseID(responseID),
      itemID: ResponsesAIOutputSpec.messageID(messageID),
      outputIndex: 0,
      contentIndex: 0,
      delta: delta,
      sequenceNumber: sequenceNumber
    )
  }

  public static func reasoningTextDelta(
    responseID: UUID, messageID: UUID, delta: String, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    ResponseStreamEvent(
      type: "response.reasoning_text.delta",
      responseID: ResponsesAIOutputSpec.responseID(responseID),
      itemID: ResponsesAIOutputSpec.messageID(messageID),
      outputIndex: 0,
      contentIndex: 0,
      delta: delta,
      sequenceNumber: sequenceNumber
    )
  }

  public static func outputTextDone(
    responseID: UUID, messageID: UUID, text: String, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    ResponseStreamEvent(
      type: "response.output_text.done",
      responseID: ResponsesAIOutputSpec.responseID(responseID),
      itemID: ResponsesAIOutputSpec.messageID(messageID),
      outputIndex: 0,
      contentIndex: 0,
      delta: nil,
      part: .init(type: "output_text", text: text, annotations: []),
      sequenceNumber: sequenceNumber
    )
  }

  public static func contentPartDone(
    responseID: UUID, messageID: UUID, text: String, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    ResponseStreamEvent(
      type: "response.content_part.done",
      responseID: ResponsesAIOutputSpec.responseID(responseID),
      itemID: ResponsesAIOutputSpec.messageID(messageID),
      outputIndex: 0,
      contentIndex: 0,
      part: .init(type: "output_text", text: text, annotations: []),
      sequenceNumber: sequenceNumber
    )
  }

  public static func messageOutputItemDone(
    responseID: UUID, messageID: UUID, text: String, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    let messageID = ResponsesAIOutputSpec.messageID(messageID)
    return ResponseStreamEvent(
      type: "response.output_item.done",
      responseID: ResponsesAIOutputSpec.responseID(responseID),
      itemID: messageID,
      outputIndex: 0,
      item: .init(
        id: messageID,
        type: "message",
        status: "completed",
        role: "assistant",
        content: [.init(type: "output_text", text: text, annotations: [])]
      ),
      sequenceNumber: sequenceNumber
    )
  }

  public static func functionCallOutput(responseID: UUID, trace: CapabilityExecutionTrace)
    -> [ResponseStreamEvent]
  {
    let itemID = ResponsesAIOutputSpec.functionCallID(trace.id)
    let output = trace.result.content.compactMap(\.text).joined()
    let item = OutputItemPayload(
      id: itemID,
      type: "function_call",
      status: trace.result.success ? "completed" : "failed",
      name: trace.request.capabilityID,
      callID: ResponsesAIOutputSpec.callID(trace.id),
      arguments: compactJSONString(from: trace.request.arguments),
      output: output.isEmpty ? nil : output,
      content: trace.result.content.map(ContentPartPayload.init(contentPart:))
    )
    return [
      ResponseStreamEvent(
        type: "response.output_item.added",
        responseID: ResponsesAIOutputSpec.responseID(responseID),
        itemID: itemID,
        outputIndex: 0,
        item: item
      ),
      ResponseStreamEvent(
        type: "response.output_item.done",
        responseID: ResponsesAIOutputSpec.responseID(responseID),
        itemID: itemID,
        outputIndex: 0,
        item: item
      ),
    ]
  }

  public static func responseCompleted(
    responseID: UUID,
    messageID: UUID? = nil,
    model: String? = nil,
    text: String? = nil,
    usage: Usage? = nil,
    metadata: [String: JSONValue] = [:],
    sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    let output: [OutputItemPayload]?
    if let messageID, let text {
      output = [
        .init(
          id: ResponsesAIOutputSpec.messageID(messageID),
          type: "message",
          status: "completed",
          role: "assistant",
          content: [.init(type: "output_text", text: text, annotations: [])]
        )
      ]
    } else {
      output = nil
    }
    let responseID = ResponsesAIOutputSpec.responseID(responseID)
    return ResponseStreamEvent(
      type: "response.completed",
      responseID: responseID,
      response: .init(
        id: responseID,
        object: "response",
        createdAt: Int(Date().timeIntervalSince1970),
        status: "completed",
        model: model,
        output: output,
        usage: usage.map { UsageMapper.dictionary(from: $0) },
        metadata: metadata,
        error: .null,
        incompleteDetails: .null,
        parallelToolCalls: true,
        toolChoice: .string("auto"),
        tools: [],
        temperature: 1,
        topP: 1,
        truncation: "disabled",
        text: .object(["format": .object(["type": .string("text")])])
      ),
      sequenceNumber: sequenceNumber
    )
  }

  public static func responseFailed(
    responseID: UUID, messageID: UUID?, description: String, sequenceNumber: Int? = nil
  ) -> ResponseStreamEvent {
    ResponseStreamEvent(
      type: "error",
      responseID: ResponsesAIOutputSpec.responseID(responseID),
      itemID: messageID.map(ResponsesAIOutputSpec.messageID),
      error: .object([
        "message": .string(description),
        "type": .string("internal_error"),
        "param": .null,
        "code": .string("internal_error"),
      ]),
      code: "internal_error",
      message: description,
      param: .null,
      sequenceNumber: sequenceNumber
    )
  }

  private static func compactJSONString(from value: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(JSONValue.object(value)),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}

extension ResponseStreamEvent.ContentPartPayload {
  public init(contentPart: ContentPart) {
    switch contentPart.kind {
    case .text:
      self.init(type: "output_text", text: contentPart.text, annotations: [])
    case .code:
      self.init(type: "output_text", text: contentPart.text, annotations: [])
    case .structured, .capabilityReference:
      self.init(
        type: contentPart.kind.rawValue, text: contentPart.text, data: contentPart.payload,
        mimeType: contentPart.mimeType)
    case .imageFile:
      self.init(
        type: "input_image", imageURL: contentPart.uri, data: contentPart.payload,
        mimeType: contentPart.mimeType)
    case .audioFile:
      self.init(
        type: "input_audio", text: contentPart.text, data: contentPart.payload,
        mimeType: contentPart.mimeType)
    case .videoFile:
      self.init(
        type: "input_video", videoURL: contentPart.uri, data: contentPart.payload,
        mimeType: contentPart.mimeType)
    }
  }
}
