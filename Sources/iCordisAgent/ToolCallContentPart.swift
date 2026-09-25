import Foundation
import iCordisKernel

/// Structured representation of a native tool call and its result inside a
/// `ConversationItem`.
///
/// The Agent trajectory needs to replay "the model asked for tool X with these
/// arguments, and the runtime answered Y" back to the model on every turn. The
/// Responses protocol carries that as two typed input items rather than as
/// prose, so the parts are modelled here — in the domain layer — and both the
/// Agent runtime and `ResponsesAPIAdapter` read the same keys.
/// Capability IDs are dotted (`william.code.file.read`); function names in the
/// tool-calling protocol are not. One sanitizer, shared by the adapter that
/// declares the tools and by the Agent that has to map a returned name back to
/// the capability it came from.
public enum ToolFunctionName {
  public static func sanitized(_ capabilityID: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    let mapped = capabilityID.unicodeScalars.map { scalar in
      allowed.contains(scalar) ? Character(scalar).description : "_"
    }.joined()
    let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "_-"))
    return String((trimmed.isEmpty ? "william_tool" : trimmed).prefix(64))
  }
}

public enum ToolCallContentPart {
  public static let functionCallType = "function_call"
  public static let functionCallOutputType = "function_call_output"

  private static let typeKey = "type"
  private static let callIDKey = "call_id"
  private static let nameKey = "name"
  private static let argumentsKey = "arguments"
  private static let outputKey = "output"

  public struct FunctionCall: Hashable, Sendable {
    public var callID: String
    public var name: String
    /// Raw JSON object string, exactly as the protocol transports it.
    public var arguments: String

    public init(callID: String, name: String, arguments: String) {
      self.callID = callID
      self.name = name
      self.arguments = arguments
    }
  }

  public struct FunctionCallOutput: Hashable, Sendable {
    public var callID: String
    public var output: String

    public init(callID: String, output: String) {
      self.callID = callID
      self.output = output
    }
  }

  public static func part(for call: FunctionCall) -> ContentPart {
    ContentPart(
      kind: .capabilityReference,
      payload: .object([
        typeKey: .string(functionCallType),
        callIDKey: .string(call.callID),
        nameKey: .string(call.name),
        argumentsKey: .string(call.arguments),
      ])
    )
  }

  public static func part(for output: FunctionCallOutput) -> ContentPart {
    ContentPart(
      kind: .capabilityReference,
      payload: .object([
        typeKey: .string(functionCallOutputType),
        callIDKey: .string(output.callID),
        outputKey: .string(output.output),
      ])
    )
  }

  public static func functionCall(from part: ContentPart) -> FunctionCall? {
    guard let object = payloadObject(from: part),
      object[typeKey]?.stringValue == functionCallType,
      let callID = object[callIDKey]?.stringValue,
      let name = object[nameKey]?.stringValue
    else {
      return nil
    }
    return FunctionCall(
      callID: callID,
      name: name,
      arguments: object[argumentsKey]?.stringValue ?? "{}"
    )
  }

  public static func functionCallOutput(from part: ContentPart) -> FunctionCallOutput? {
    guard let object = payloadObject(from: part),
      object[typeKey]?.stringValue == functionCallOutputType,
      let callID = object[callIDKey]?.stringValue
    else {
      return nil
    }
    return FunctionCallOutput(callID: callID, output: object[outputKey]?.stringValue ?? "")
  }

  /// True for any part that must be serialized as its own typed input item
  /// instead of being folded into a role message's content array.
  public static func isToolCallPart(_ part: ContentPart) -> Bool {
    functionCall(from: part) != nil || functionCallOutput(from: part) != nil
  }

  private static func payloadObject(from part: ContentPart) -> [String: JSONValue]? {
    guard part.kind == .capabilityReference,
      case .object(let object)? = part.payload
    else {
      return nil
    }
    return object
  }
}
