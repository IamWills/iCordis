import Foundation

/// Accumulates a native or Chat Completions tool call whose id, name, and
/// argument JSON arrive as separate stream fragments.
///
/// `NativeAgentStreamReducer` and `ChatCompletionsStreamAccumulator` both
/// delegate here so a host or adapter can assemble calls without copying
/// either reducer.
public struct StreamingToolCallAssembler<Key: Hashable & Sendable>: Sendable {
  public struct Fragment: Sendable, Equatable {
    public var name: String
    public var callID: String
    public var arguments: String
    public var isComplete: Bool

    public init(
      name: String, callID: String, arguments: String = "", isComplete: Bool = false
    ) {
      self.name = name
      self.callID = callID
      self.arguments = arguments
      self.isComplete = isComplete
    }
  }

  private var fragments: [Key: Fragment] = [:]
  private var order: [Key] = []

  public init() {}

  /// Inserts a call or fills in a name/id that arrived after the first fragment.
  /// Empty name and callID never overwrite a value already stored.
  /// `fallbackCallID` is used only when the call is first seen without an id.
  public mutating func register(
    key: Key, name: String, callID: String, fallbackCallID: String = ""
  ) {
    if fragments[key] == nil {
      let resolved = callID.isEmpty ? fallbackCallID : callID
      fragments[key] = Fragment(name: name, callID: resolved)
      order.append(key)
    } else {
      if !name.isEmpty { fragments[key]?.name = name }
      if !callID.isEmpty { fragments[key]?.callID = callID }
    }
  }

  /// Appends an argument delta. Creates a placeholder when a gateway streams
  /// arguments before announcing the item. Deltas after `complete` are ignored.
  public mutating func appendArguments(_ delta: String, key: Key, fallbackCallID: String) {
    guard !delta.isEmpty else { return }
    if fragments[key] == nil {
      fragments[key] = Fragment(name: "", callID: fallbackCallID)
      order.append(key)
    }
    guard fragments[key]?.isComplete == false else { return }
    fragments[key]?.arguments += delta
  }

  /// Replaces the accumulated argument string with the terminal payload.
  public mutating func complete(arguments: String, key: Key) {
    guard !arguments.isEmpty, fragments[key] != nil else { return }
    fragments[key]?.arguments = arguments
    fragments[key]?.isComplete = true
  }

  public func ordered() -> [(key: Key, fragment: Fragment)] {
    order.compactMap { key in
      fragments[key].map { (key, $0) }
    }
  }

  public static func decodeArguments(_ raw: String) -> [String: JSONValue] {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty,
      let data = trimmed.data(using: .utf8),
      let value = try? JSONDecoder().decode(JSONValue.self, from: data),
      case .object(let object) = value
    else {
      return [:]
    }
    return object
  }
}
