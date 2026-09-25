import Foundation

/// A service implementation packaged as a reversible plugin. Use a stable id per provider.
public struct ServiceProviderPlugin<Service: WilliamService>: WilliamPlugin {
  public static var manifest: PluginManifest {
    PluginManifest(
      id: PluginID("icordis.service-provider"), name: "Service Provider",
      version: SemanticVersion(1))
  }
  public let manifest: PluginManifest
  public let key: ServiceKey<Service>
  public let service: Service
  private let dispose: EffectDisposer?

  public init(
    id: String, name: String, service: Service, key: ServiceKey<Service>,
    requiredServices: Set<ServiceID> = [], dispose: EffectDisposer? = nil
  ) {
    self.manifest = PluginManifest(
      id: PluginID(id), name: name, version: SemanticVersion(1),
      requiredServices: requiredServices, providedServices: [key.id])
    self.key = key
    self.service = service
    self.dispose = dispose
  }
  public func apply(to context: PluginContext) async throws {
    if let dispose {
      try await context.effect(label: "service-provider.shutdown", dispose: dispose)
    }
    try await context.provide(service, as: key)
  }
}

public typealias Kernel = WilliamKernel
public typealias Plugin = WilliamPlugin
public typealias Service = WilliamService
public typealias Scope = WilliamScope
public typealias ScopeKind = WilliamScopeKind
public typealias Platform = WilliamPlatform
public typealias Preset = WilliamPreset
public typealias RuntimeHost = WilliamRuntimeHost
