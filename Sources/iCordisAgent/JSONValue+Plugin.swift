import Foundation

extension JSONValue {
  public var pluginObjectValue: [String: JSONValue]? {
    if case .object(let value) = self { return value }
    return nil
  }

  public var pluginArrayValue: [JSONValue]? {
    if case .array(let value) = self { return value }
    return nil
  }

  public var pluginBoolValue: Bool? {
    if case .bool(let value) = self { return value }
    return nil
  }

  public var pluginNumberValue: Double? {
    if case .number(let value) = self { return value }
    return nil
  }

  public var pluginProtocolIdentifier: String? {
    switch self {
    case .string(let value): value
    case .number(let value): String(format: "%.0f", value)
    default: nil
    }
  }
}
