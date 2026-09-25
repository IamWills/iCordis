import Foundation
import iCordisKernel

public enum LongTermMemoryKind: String, Codable, CaseIterable, Sendable {
  case preference
  case profile
  case project
  case decision
  case constraint
  case other
}

public enum LongTermMemoryScopeKind: String, Codable, CaseIterable, Sendable {
  case global
  case workspace
}

public struct LongTermMemoryScope: Codable, Hashable, Sendable {
  public var kind: LongTermMemoryScopeKind
  /// A one-way identifier; workspace paths are never persisted as scope IDs.
  public var identifier: String?
  public var displayName: String?

  public static let global = LongTermMemoryScope(
    kind: .global, identifier: nil, displayName: "Global")

  public init(kind: LongTermMemoryScopeKind, identifier: String? = nil, displayName: String? = nil)
  {
    self.kind = kind
    self.identifier = identifier
    self.displayName = displayName
  }
}

public enum LongTermMemoryStatus: String, Codable, Sendable {
  case active
  case superseded
}

public struct LongTermMemorySource: Codable, Hashable, Sendable {
  public var sessionID: UUID
  public var messageID: UUID?
  public var explicitlyConfirmed: Bool

  public init(sessionID: UUID, messageID: UUID? = nil, explicitlyConfirmed: Bool) {
    self.sessionID = sessionID
    self.messageID = messageID
    self.explicitlyConfirmed = explicitlyConfirmed
  }
}

public struct LongTermMemoryRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var kind: LongTermMemoryKind
  public var scope: LongTermMemoryScope
  /// A concise, atomic user fact or preference—not a raw conversation dump.
  public var content: String
  public var normalizedContent: String
  public var source: LongTermMemorySource
  public var confidence: Double
  public var isPinned: Bool
  public var status: LongTermMemoryStatus
  public var supersededBy: UUID?
  public var expiresAt: Date?
  public var createdAt: Date
  public var updatedAt: Date

  public var isAvailable: Bool {
    guard status == .active else { return false }
    guard let expiresAt else { return true }
    return expiresAt > .now
  }

  public init(
    id: UUID, kind: LongTermMemoryKind, scope: LongTermMemoryScope, content: String,
    normalizedContent: String, source: LongTermMemorySource, confidence: Double, isPinned: Bool,
    status: LongTermMemoryStatus, supersededBy: UUID? = nil, expiresAt: Date? = nil,
    createdAt: Date, updatedAt: Date
  ) {
    self.id = id
    self.kind = kind
    self.scope = scope
    self.content = content
    self.normalizedContent = normalizedContent
    self.source = source
    self.confidence = confidence
    self.isPinned = isPinned
    self.status = status
    self.supersededBy = supersededBy
    self.expiresAt = expiresAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

public struct LongTermMemoryContext: Sendable, Hashable {
  public var records: [LongTermMemoryRecord]
  public var rendered: String

  public static let empty = LongTermMemoryContext(records: [], rendered: "")

  public init(records: [LongTermMemoryRecord], rendered: String) {
    self.records = records
    self.rendered = rendered
  }
}

public struct LongTermMemoryWriteRequest: Sendable, Hashable {
  public var content: String
  public var kind: LongTermMemoryKind
  public var scope: LongTermMemoryScope
  public var source: LongTermMemorySource
  public var confidence: Double = 1
  public var isPinned: Bool = false
  public var expiresAt: Date? = nil

  public init(
    content: String, kind: LongTermMemoryKind, scope: LongTermMemoryScope,
    source: LongTermMemorySource, confidence: Double = 1, isPinned: Bool = false,
    expiresAt: Date? = nil
  ) {
    self.content = content
    self.kind = kind
    self.scope = scope
    self.source = source
    self.confidence = confidence
    self.isPinned = isPinned
    self.expiresAt = expiresAt
  }
}
