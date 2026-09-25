import Foundation

public enum KernelPluginState: String, Codable, Hashable, Sendable {
  case discovered
  case validating
  case validated
  case unresolved
  case loading
  case applying
  case active
  case suspending
  case suspended
  case disposing
  case unloaded
  case failed
}

public struct PluginRegistrySnapshot: Sendable, Equatable {
  public let manifest: PluginManifest
  public let state: KernelPluginState
  public let missingPlugins: Set<PluginID>
  public let missingServices: Set<ServiceID>
  public let lastError: String?
  public let activationCount: Int

  public init(
    manifest: PluginManifest, state: KernelPluginState, missingPlugins: Set<PluginID>,
    missingServices: Set<ServiceID>, lastError: String? = nil, activationCount: Int
  ) {
    self.manifest = manifest
    self.state = state
    self.missingPlugins = missingPlugins
    self.missingServices = missingServices
    self.lastError = lastError
    self.activationCount = activationCount
  }
}

public actor PluginRegistry {
  public init() {}
  private struct Entry: Sendable {
    let manifest: PluginManifest
    var state: KernelPluginState
    var missingPlugins: Set<PluginID>
    var missingServices: Set<ServiceID>
    var lastError: String?
    var activationCount: Int
  }

  private var entries: [PluginID: Entry] = [:]

  public func discover(_ manifest: PluginManifest) throws {
    if let existing = entries[manifest.id], existing.state != .unloaded && existing.state != .failed
    {
      throw PluginContractError.duplicatePlugin(manifest.id)
    }
    entries[manifest.id] = Entry(
      manifest: manifest,
      state: .discovered,
      missingPlugins: [],
      missingServices: [],
      lastError: nil,
      activationCount: entries[manifest.id]?.activationCount ?? 0
    )
  }

  public func update(
    _ pluginID: PluginID,
    state: KernelPluginState,
    missingPlugins: Set<PluginID> = [],
    missingServices: Set<ServiceID> = [],
    error: String? = nil
  ) throws {
    guard var entry = entries[pluginID] else {
      throw PluginContractError.pluginNotMounted(pluginID)
    }
    entry.state = state
    entry.missingPlugins = missingPlugins
    entry.missingServices = missingServices
    entry.lastError = error
    if state == .active {
      entry.activationCount += 1
    }
    entries[pluginID] = entry
  }

  public func snapshot(for pluginID: PluginID) throws -> PluginRegistrySnapshot {
    guard let entry = entries[pluginID] else {
      throw PluginContractError.pluginNotMounted(pluginID)
    }
    return Self.snapshot(entry)
  }

  public func snapshots() -> [PluginRegistrySnapshot] {
    entries.values.map(Self.snapshot).sorted { $0.manifest.id.rawValue < $1.manifest.id.rawValue }
  }

  private static func snapshot(_ entry: Entry) -> PluginRegistrySnapshot {
    PluginRegistrySnapshot(
      manifest: entry.manifest,
      state: entry.state,
      missingPlugins: entry.missingPlugins,
      missingServices: entry.missingServices,
      lastError: entry.lastError,
      activationCount: entry.activationCount
    )
  }
}
