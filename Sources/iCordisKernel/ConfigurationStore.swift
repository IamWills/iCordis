import Foundation

public struct ConfigurationKey<Value: Sendable>: Hashable, Sendable {
  public let id: String
  public let defaultValue: Value

  public init(_ id: String, default defaultValue: Value) {
    self.id = id
    self.defaultValue = defaultValue
  }

  public static func == (lhs: ConfigurationKey<Value>, rhs: ConfigurationKey<Value>) -> Bool {
    lhs.id == rhs.id
  }

  public func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

public enum ConfigurationStoreError: Error, LocalizedError, Sendable, Equatable {
  case typeMismatch(key: String, expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .typeMismatch(let key, let expected, let actual):
      "Configuration \(key) expected \(expected), but contains \(actual)."
    }
  }
}

public actor ConfigurationStore {
  public init() {}
  private struct Entry: Sendable {
    let value: any Sendable
    let type: String
  }

  private var values: [String: Entry] = [:]

  public func value<Value: Sendable>(for key: ConfigurationKey<Value>) throws -> Value {
    guard let entry = values[key.id] else { return key.defaultValue }
    guard let value = entry.value as? Value else {
      throw ConfigurationStoreError.typeMismatch(
        key: key.id,
        expected: String(reflecting: Value.self),
        actual: entry.type
      )
    }
    return value
  }

  public func set<Value: Sendable>(_ value: Value, for key: ConfigurationKey<Value>) {
    values[key.id] = Entry(value: value, type: String(reflecting: Value.self))
  }

  public func remove<Value: Sendable>(_ key: ConfigurationKey<Value>) {
    values.removeValue(forKey: key.id)
  }
}
