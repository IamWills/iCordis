import Foundation

public enum PluginContextError: Error, LocalizedError, Sendable, Equatable {
  case undeclaredService(pluginID: PluginID, serviceID: ServiceID)

  public var errorDescription: String? {
    switch self {
    case .undeclaredService(let pluginID, let serviceID):
      "Plugin \(pluginID) attempted to provide undeclared service \(serviceID)."
    }
  }
}

public struct PluginContext: Sendable {
  public let pluginID: PluginID
  public let declaredServices: Set<ServiceID>
  public let scope: WilliamScope
  public let services: ServiceRegistry
  public let events: EventBus
  public let configuration: ConfigurationStore
  /// Applied by `provide` when a call does not name its own policy. The kernel
  /// sets this to `.replace` when a plugin is mounted as a slot replacement, so
  /// an ordinary provider becomes a reversible replacement without the plugin
  /// having to know it is replacing anything.
  public var defaultConflictPolicy: ServiceConflictPolicy = .reject

  public func service<Service: WilliamService>(_ key: ServiceKey<Service>) async throws -> Service {
    try await services.resolve(key)
  }

  public func optionalService<Service: WilliamService>(_ key: ServiceKey<Service>) async throws
    -> Service?
  {
    try await services.optional(key)
  }

  public func provide<Service: WilliamService>(
    _ service: Service,
    as key: ServiceKey<Service>,
    conflictPolicy: ServiceConflictPolicy? = nil
  ) async throws {
    guard declaredServices.contains(key.id) else {
      throw PluginContextError.undeclaredService(pluginID: pluginID, serviceID: key.id)
    }
    let lease = try await services.provide(
      service,
      for: key,
      provider: pluginID,
      scopeID: scope.id,
      conflictPolicy: conflictPolicy ?? defaultConflictPolicy
    )
    do {
      try await scope.effects.add(label: "service:\(key.id)") {
        await services.remove(lease)
      }
    } catch {
      await services.remove(lease)
      throw error
    }
  }

  public func effect(label: String, dispose: @escaping EffectDisposer) async throws {
    try await scope.effects.add(label: label, dispose: dispose)
  }

  public func acquireEffect(
    label: String,
    _ operation: @Sendable () async throws -> EffectDisposer
  ) async throws {
    try await scope.effects.acquire(label: label, operation)
  }

  public func makeScope(kind: WilliamScopeKind) async throws -> WilliamScope {
    try await scope.makeChild(kind: kind)
  }

  public func on<Payload: Sendable>(
    _ event: NotificationEvent<Payload>,
    priority: Int = 0,
    handler: @escaping @Sendable (Payload) async throws -> Void
  ) async throws {
    let subscription = try await events.on(
      event, owner: pluginID, priority: priority, handler: handler)
    try await own(subscription)
  }

  public func on<Payload: Sendable, Response: Sendable>(
    _ event: SerialEvent<Payload, Response>,
    priority: Int = 0,
    handler: @escaping @Sendable (Payload) async throws -> Response?
  ) async throws {
    let subscription = try await events.on(
      event, owner: pluginID, priority: priority, handler: handler)
    try await own(subscription)
  }

  public func on<Payload: Sendable, Response: Sendable>(
    _ event: ParallelEvent<Payload, Response>,
    priority: Int = 0,
    handler: @escaping @Sendable (Payload) async throws -> Response
  ) async throws {
    let subscription = try await events.on(
      event, owner: pluginID, priority: priority, handler: handler)
    try await own(subscription)
  }

  public func on<Value: Sendable>(
    _ event: TransformEvent<Value>,
    priority: Int = 0,
    handler: @escaping @Sendable (Value) async throws -> Value
  ) async throws {
    let subscription = try await events.on(
      event, owner: pluginID, priority: priority, handler: handler)
    try await own(subscription)
  }

  public func on<Request: Sendable, Response: Sendable>(
    _ event: MiddlewareEvent<Request, Response>,
    priority: Int = 0,
    handler:
      @escaping @Sendable (Request, @escaping EventNext<Request, Response>) async throws -> Response
  ) async throws {
    let subscription = try await events.on(
      event, owner: pluginID, priority: priority, handler: handler)
    try await own(subscription)
  }

  private func own(_ subscription: EventSubscription) async throws {
    do {
      try await scope.effects.add(label: "event:\(subscription.eventID)") {
        await events.remove(subscription)
      }
    } catch {
      await events.remove(subscription)
      throw error
    }
  }

  public init(
    pluginID: PluginID, declaredServices: Set<ServiceID>, scope: WilliamScope,
    services: ServiceRegistry, events: EventBus, configuration: ConfigurationStore,
    defaultConflictPolicy: ServiceConflictPolicy = .reject
  ) {
    self.pluginID = pluginID
    self.declaredServices = declaredServices
    self.scope = scope
    self.services = services
    self.events = events
    self.configuration = configuration
    self.defaultConflictPolicy = defaultConflictPolicy
  }
}
