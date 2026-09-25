import Foundation

public typealias EffectDisposer = @Sendable () async throws -> Void

public enum EffectScopeState: String, Sendable {
  case active
  case disposing
  case disposed
}

public struct EffectSnapshot: Sendable, Equatable {
  public let label: String
  public let registrationOrder: UInt64

  public init(label: String, registrationOrder: UInt64) {
    self.label = label
    self.registrationOrder = registrationOrder
  }
}

public struct EffectScopeSnapshot: Sendable, Equatable {
  public let id: UUID
  public let state: EffectScopeState
  public let effects: [EffectSnapshot]

  public init(id: UUID, state: EffectScopeState, effects: [EffectSnapshot]) {
    self.id = id
    self.state = state
    self.effects = effects
  }
}

public enum EffectScopeError: Error, LocalizedError, Sendable, Equatable {
  case inactive(scopeID: UUID)
  case cleanupFailed([String])

  public var errorDescription: String? {
    switch self {
    case .inactive(let scopeID):
      "Cannot register an effect on inactive scope \(scopeID)."
    case .cleanupFailed(let failures):
      "Effect cleanup failed: \(failures.joined(separator: "; "))"
    }
  }
}

public actor EffectScope {
  private struct Entry: Sendable {
    let label: String
    let order: UInt64
    let dispose: EffectDisposer
  }

  public nonisolated let id: UUID
  private var state: EffectScopeState = .active
  private var nextOrder: UInt64 = 0
  private var entries: [Entry] = []
  private var disposalTask: Task<[String], Never>?

  public init(id: UUID = UUID()) {
    self.id = id
  }

  public func add(label: String, dispose: @escaping EffectDisposer) throws {
    guard state == .active else {
      throw EffectScopeError.inactive(scopeID: id)
    }
    entries.append(Entry(label: label, order: nextOrder, dispose: dispose))
    nextOrder += 1
  }

  public func acquire(
    label: String,
    _ operation: @Sendable () async throws -> EffectDisposer
  ) async throws {
    guard state == .active else {
      throw EffectScopeError.inactive(scopeID: id)
    }
    let disposer = try await operation()
    do {
      try add(label: label, dispose: disposer)
    } catch {
      try? await disposer()
      throw error
    }
  }

  public func dispose() async throws {
    if state == .disposed {
      return
    }

    let task: Task<[String], Never>
    if let disposalTask {
      task = disposalTask
    } else {
      state = .disposing
      let pending = Array(entries.reversed())
      entries.removeAll(keepingCapacity: false)
      let createdTask = Task {
        var failures: [String] = []
        for entry in pending {
          do {
            try await entry.dispose()
          } catch {
            failures.append("\(entry.label): \(error.localizedDescription)")
          }
        }
        return failures
      }
      disposalTask = createdTask
      task = createdTask
    }

    let failures = await task.value
    state = .disposed
    disposalTask = nil
    if !failures.isEmpty {
      throw EffectScopeError.cleanupFailed(failures)
    }
  }

  public func snapshot() -> EffectScopeSnapshot {
    EffectScopeSnapshot(
      id: id,
      state: state,
      effects: entries.map { EffectSnapshot(label: $0.label, registrationOrder: $0.order) }
    )
  }
}
