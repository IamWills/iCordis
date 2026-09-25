import Foundation

public enum WilliamScopeKind: String, Codable, Hashable, Sendable {
  case application
  case conversation
  case agentRun
  case plugin
  case toolExecution
}
public struct ScopeID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: UUID

  public init(rawValue: UUID = UUID()) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue.uuidString }
}

public struct WilliamScopeSnapshot: Sendable, Equatable {
  public let id: ScopeID
  public let kind: WilliamScopeKind
  public let parentID: ScopeID?
  public let effects: EffectScopeSnapshot
  public let children: [WilliamScopeSnapshot]

  public init(
    id: ScopeID, kind: WilliamScopeKind, parentID: ScopeID? = nil, effects: EffectScopeSnapshot,
    children: [WilliamScopeSnapshot]
  ) {
    self.id = id
    self.kind = kind
    self.parentID = parentID
    self.effects = effects
    self.children = children
  }
}

public actor WilliamScope {
  public nonisolated let id: ScopeID
  public nonisolated let kind: WilliamScopeKind
  public nonisolated let parentID: ScopeID?
  public nonisolated let effects: EffectScope

  private var children: [ScopeID: WilliamScope] = [:]

  public init(
    id: ScopeID = ScopeID(),
    kind: WilliamScopeKind,
    parentID: ScopeID? = nil,
    effects: EffectScope = EffectScope()
  ) {
    self.id = id
    self.kind = kind
    self.parentID = parentID
    self.effects = effects
  }

  public func makeChild(kind: WilliamScopeKind) async throws -> WilliamScope {
    let child = WilliamScope(kind: kind, parentID: id)
    try await effects.add(label: "child-scope:\(child.id)") {
      try await child.dispose()
    }
    children[child.id] = child
    return child
  }

  public func dispose() async throws {
    try await effects.dispose()
    children.removeAll(keepingCapacity: false)
  }

  public func snapshot() async -> WilliamScopeSnapshot {
    var childSnapshots: [WilliamScopeSnapshot] = []
    for child in children.values {
      childSnapshots.append(await child.snapshot())
    }
    childSnapshots.sort { $0.id.description < $1.id.description }
    return WilliamScopeSnapshot(
      id: id,
      kind: kind,
      parentID: parentID,
      effects: await effects.snapshot(),
      children: childSnapshots
    )
  }
}
