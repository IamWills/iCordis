import Foundation

public actor WilliamKernel {
  public nonisolated let services: ServiceRegistry
  public nonisolated let events: EventBus
  public nonisolated let configuration: ConfigurationStore
  public nonisolated let plugins: PluginRegistry
  public nonisolated let applicationScope: WilliamScope

  private struct MountedPlugin: Sendable {
    let plugin: any WilliamPlugin
    let manifest: PluginManifest
    var scope: WilliamScope?
    var state: KernelPluginState
    /// The default conflict policy this plugin's `provide` calls inherit.
    /// `.replace` means it was mounted as a reversible slot replacement.
    var conflictPolicy: ServiceConflictPolicy = .reject
  }

  private var mounted: [PluginID: MountedPlugin] = [:]

  public init(
    services: ServiceRegistry = ServiceRegistry(),
    events: EventBus = EventBus(),
    configuration: ConfigurationStore = ConfigurationStore(),
    plugins: PluginRegistry = PluginRegistry(),
    applicationScope: WilliamScope = WilliamScope(kind: .application)
  ) {
    self.services = services
    self.events = events
    self.configuration = configuration
    self.plugins = plugins
    self.applicationScope = applicationScope
  }

  /// Mounts a plugin. `conflictPolicy` is the default policy its `provide`
  /// calls inherit: pass `.replace` to mount it as a reversible replacement of
  /// whatever slots it provides — unmounting it later reveals the previous
  /// provider. This is how any capability slot is swapped at runtime.
  @discardableResult
  public
    func mount(
      _ plugin: any WilliamPlugin,
      conflictPolicy: ServiceConflictPolicy = .reject
    ) async throws -> PluginRegistrySnapshot
  {
    let manifest = plugin.manifest
    try validate(manifest)
    guard mounted[manifest.id] == nil else {
      throw PluginContractError.duplicatePlugin(manifest.id)
    }

    try await plugins.discover(manifest)
    mounted[manifest.id] = MountedPlugin(
      plugin: plugin,
      manifest: manifest,
      scope: nil,
      state: .discovered,
      conflictPolicy: conflictPolicy
    )
    await transition(manifest.id, to: .discovered)
    await transition(manifest.id, to: .validating)
    await transition(manifest.id, to: .validated)
    do {
      try await reconcile(primaryPluginID: manifest.id)
    } catch {
      throw error
    }
    return try await plugins.snapshot(for: manifest.id)
  }

  @discardableResult
  public
    func unmount(_ pluginID: PluginID) async throws -> PluginRegistrySnapshot
  {
    guard mounted[pluginID] != nil else {
      throw PluginContractError.pluginNotMounted(pluginID)
    }
    try await deactivateDependants(of: pluginID, visited: [])
    try await deactivate(pluginID, finalState: .unloaded)
    mounted.removeValue(forKey: pluginID)
    try await reconcile(primaryPluginID: nil)
    return try await plugins.snapshot(for: pluginID)
  }

  @discardableResult
  public
    func reload(_ pluginID: PluginID) async throws -> PluginRegistrySnapshot
  {
    guard let record = mounted[pluginID] else {
      throw PluginContractError.pluginNotMounted(pluginID)
    }
    let existing = record.plugin
    let policy = record.conflictPolicy
    _ = try await unmount(pluginID)
    return try await mount(existing, conflictPolicy: policy)
  }

  @discardableResult
  public
    func suspend(_ pluginID: PluginID) async throws -> PluginRegistrySnapshot
  {
    guard mounted[pluginID] != nil else {
      throw PluginContractError.pluginNotMounted(pluginID)
    }
    try await deactivateDependants(of: pluginID, visited: [])
    await transition(pluginID, to: .suspending)
    try await deactivate(pluginID, finalState: .suspended)
    try await reconcile(primaryPluginID: nil)
    return try await plugins.snapshot(for: pluginID)
  }

  @discardableResult
  public
    func resume(_ pluginID: PluginID) async throws -> PluginRegistrySnapshot
  {
    guard let record = mounted[pluginID], record.state == .suspended else {
      throw PluginContractError.pluginNotMounted(pluginID)
    }
    await transition(pluginID, to: .validated)
    try await reconcile(primaryPluginID: pluginID)
    return try await plugins.snapshot(for: pluginID)
  }

  public func shutdown() async throws {
    let ids = mounted.keys.sorted { $0.rawValue > $1.rawValue }
    var failures: [String] = []
    for pluginID in ids where mounted[pluginID] != nil {
      do {
        _ = try await unmount(pluginID)
      } catch {
        failures.append("\(pluginID): \(error.localizedDescription)")
      }
    }
    do {
      try await applicationScope.dispose()
    } catch {
      failures.append("application scope: \(error.localizedDescription)")
    }
    if !failures.isEmpty {
      throw EffectScopeError.cleanupFailed(failures)
    }
  }

  public func diagnostics() async -> KernelDiagnosticsSnapshot {
    async let pluginSnapshots = plugins.snapshots()
    async let serviceSnapshots = services.snapshots()
    async let eventSnapshots = events.snapshots()
    async let scopeSnapshot = applicationScope.snapshot()
    var pluginScopeSnapshots: [WilliamScopeSnapshot] = []
    for scope in mounted.values.compactMap(\.scope) {
      pluginScopeSnapshots.append(await scope.snapshot())
    }
    pluginScopeSnapshots.sort { $0.id.description < $1.id.description }
    return await KernelDiagnosticsSnapshot(
      plugins: pluginSnapshots,
      services: serviceSnapshots,
      eventHandlers: eventSnapshots,
      applicationScope: scopeSnapshot,
      pluginScopes: pluginScopeSnapshots
    )
  }

  private func validate(_ manifest: PluginManifest) throws {
    let trimmedID = manifest.id.rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedID.isEmpty, trimmedID == manifest.id.rawValue else {
      throw PluginContractError.invalidManifest(
        pluginID: manifest.id, reason: "id must be non-empty and trimmed")
    }
    guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      throw PluginContractError.invalidManifest(
        pluginID: manifest.id, reason: "name must be non-empty")
    }
    let requiredPluginIDs = Set(manifest.dependencies.map(\.id))
    let optionalPluginIDs = Set(manifest.optionalDependencies.map(\.id))
    guard requiredPluginIDs.isDisjoint(with: optionalPluginIDs) else {
      throw PluginContractError.invalidManifest(
        pluginID: manifest.id,
        reason: "a plugin dependency cannot be both required and optional"
      )
    }
    guard manifest.requiredServices.isDisjoint(with: manifest.optionalServices) else {
      throw PluginContractError.invalidManifest(
        pluginID: manifest.id,
        reason: "a service dependency cannot be both required and optional"
      )
    }
    guard manifest.supportedPlatforms.contains(.current) else {
      throw PluginContractError.unsupportedPlatform(pluginID: manifest.id, platform: .current)
    }
    guard manifest.origin == .builtIn || manifest.origin == .localDevelopment else {
      throw PluginContractError.invalidManifest(
        pluginID: manifest.id,
        reason: "Phase 1 supports built-in and local-development plugins only"
      )
    }
  }

  private func reconcile(primaryPluginID: PluginID?) async throws {
    var madeProgress = true
    while madeProgress {
      madeProgress = false
      let candidates = mounted.keys.sorted { $0.rawValue < $1.rawValue }
      for pluginID in candidates {
        guard let record = mounted[pluginID],
          record.state == .validated || record.state == .unresolved
        else {
          continue
        }
        let missing = await missingRequirements(for: record.manifest)
        if !missing.plugins.isEmpty || !missing.services.isEmpty {
          await transition(
            pluginID,
            to: .unresolved,
            missingPlugins: missing.plugins,
            missingServices: missing.services
          )
          continue
        }
        do {
          try await activate(pluginID)
          madeProgress = true
        } catch {
          if pluginID == primaryPluginID {
            throw error
          }
        }
      }
    }
  }

  private func missingRequirements(
    for manifest: PluginManifest
  ) async -> (plugins: Set<PluginID>, services: Set<ServiceID>) {
    var missingPlugins: Set<PluginID> = []
    for dependency in manifest.dependencies {
      guard let provider = mounted[dependency.id],
        provider.state == .active,
        dependency.version.accepts(provider.manifest.version)
      else {
        missingPlugins.insert(dependency.id)
        continue
      }
    }
    var missingServices: Set<ServiceID> = []
    for serviceID in manifest.requiredServices where await !services.contains(serviceID) {
      missingServices.insert(serviceID)
    }
    return (missingPlugins, missingServices)
  }

  private func activate(_ pluginID: PluginID) async throws {
    guard var record = mounted[pluginID] else {
      throw PluginContractError.pluginNotMounted(pluginID)
    }
    let scope = WilliamScope(kind: .plugin, parentID: applicationScope.id)
    record.scope = scope
    record.state = .loading
    mounted[pluginID] = record
    await transition(pluginID, to: .loading)

    let context = PluginContext(
      pluginID: pluginID,
      declaredServices: record.manifest.providedServices,
      scope: scope,
      services: services,
      events: events,
      configuration: configuration,
      defaultConflictPolicy: record.conflictPolicy
    )
    do {
      record.state = .applying
      mounted[pluginID] = record
      await transition(pluginID, to: .applying)
      try await record.plugin.apply(to: context)
      for serviceID in record.manifest.providedServices {
        guard await services.currentProvider(for: serviceID) == pluginID else {
          throw PluginContractError.advertisedServiceMissing(
            pluginID: pluginID,
            serviceID: serviceID
          )
        }
      }
      record.state = .active
      mounted[pluginID] = record
      await transition(pluginID, to: .active)
    } catch {
      try? await scope.dispose()
      record.scope = nil
      record.state = .failed
      mounted[pluginID] = record
      await transition(pluginID, to: .failed, error: error.localizedDescription)
      throw error
    }
  }

  private func deactivateDependants(
    of providerID: PluginID,
    visited: Set<PluginID>
  ) async throws {
    guard !visited.contains(providerID), let provider = mounted[providerID] else { return }
    let nextVisited = visited.union([providerID])
    let serviceIDs = provider.manifest.providedServices
    let dependantIDs = mounted.values
      .filter { candidate in
        candidate.state == .active
          && candidate.manifest.id != providerID
          && (candidate.manifest.dependencies.contains { $0.id == providerID }
            || !candidate.manifest.requiredServices.isDisjoint(with: serviceIDs))
      }
      .map { $0.manifest.id }
      .sorted { $0.rawValue < $1.rawValue }

    for dependantID in dependantIDs {
      try await deactivateDependants(of: dependantID, visited: nextVisited)
      try await deactivate(dependantID, finalState: .unresolved)
    }
  }

  private func deactivate(_ pluginID: PluginID, finalState: KernelPluginState) async throws {
    guard var record = mounted[pluginID] else { return }
    guard
      record.state == .active
        || record.state == .failed
        || record.state == .unresolved
        || record.state == .suspending
    else {
      return
    }
    if record.state == .active || record.state == .suspending {
      record.state = .disposing
      mounted[pluginID] = record
      await transition(pluginID, to: .disposing)
      if let scope = record.scope {
        do {
          try await scope.dispose()
        } catch {
          record.scope = nil
          record.state = finalState
          mounted[pluginID] = record
          await transition(pluginID, to: finalState, error: error.localizedDescription)
          throw error
        }
      }
    }
    record.scope = nil
    record.state = finalState
    mounted[pluginID] = record
    let missing =
      finalState == .unresolved
      ? await missingRequirements(for: record.manifest)
      : (plugins: Set<PluginID>(), services: Set<ServiceID>())
    await transition(
      pluginID,
      to: finalState,
      missingPlugins: missing.plugins,
      missingServices: missing.services
    )
  }

  private func transition(
    _ pluginID: PluginID,
    to state: KernelPluginState,
    missingPlugins: Set<PluginID> = [],
    missingServices: Set<ServiceID> = [],
    error: String? = nil
  ) async {
    if var record = mounted[pluginID] {
      record.state = state
      mounted[pluginID] = record
    }
    try? await plugins.update(
      pluginID,
      state: state,
      missingPlugins: missingPlugins,
      missingServices: missingServices,
      error: error
    )
    let observation = PluginLifecycleObservation(
      eventID: UUID(),
      pluginID: pluginID,
      state: state,
      timestamp: .now,
      missingPlugins: missingPlugins,
      missingServices: missingServices,
      error: error
    )
    try? await events.emit(KernelEvents.pluginLifecycle, payload: observation)
  }
}
