import Foundation

public struct KernelDiagnosticsSnapshot: Sendable, Equatable {
  public let plugins: [PluginRegistrySnapshot]
  public let services: [ServiceRegistrationSnapshot]
  public let eventHandlers: [EventHandlerSnapshot]
  public let applicationScope: WilliamScopeSnapshot
  public let pluginScopes: [WilliamScopeSnapshot]

  public func provider(of serviceID: ServiceID) -> PluginID? {
    services.last { $0.serviceID == serviceID }?.providerPluginID
  }

  public func listeners(for eventID: EventID) -> [EventHandlerSnapshot] {
    eventHandlers.filter { $0.eventID == eventID }
  }

  public func plugin(_ pluginID: PluginID) -> PluginRegistrySnapshot? {
    plugins.first { $0.manifest.id == pluginID }
  }

  public init(
    plugins: [PluginRegistrySnapshot], services: [ServiceRegistrationSnapshot],
    eventHandlers: [EventHandlerSnapshot], applicationScope: WilliamScopeSnapshot,
    pluginScopes: [WilliamScopeSnapshot]
  ) {
    self.plugins = plugins
    self.services = services
    self.eventHandlers = eventHandlers
    self.applicationScope = applicationScope
    self.pluginScopes = pluginScopes
  }
}

public struct PluginLifecycleObservation: Sendable, Equatable {
  public let eventID: UUID
  public let pluginID: PluginID
  public let state: KernelPluginState
  public let timestamp: Date
  public let missingPlugins: Set<PluginID>
  public let missingServices: Set<ServiceID>
  public let error: String?

  public init(
    eventID: UUID, pluginID: PluginID, state: KernelPluginState, timestamp: Date,
    missingPlugins: Set<PluginID>, missingServices: Set<ServiceID>, error: String? = nil
  ) {
    self.eventID = eventID
    self.pluginID = pluginID
    self.state = state
    self.timestamp = timestamp
    self.missingPlugins = missingPlugins
    self.missingServices = missingServices
    self.error = error
  }
}

public enum KernelEvents {
  public static let pluginLifecycle = NotificationEvent<PluginLifecycleObservation>(
    EventID("plugin/lifecycle")
  )
}
