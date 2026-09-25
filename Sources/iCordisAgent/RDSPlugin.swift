import Foundation
import iCordisKernel

public struct RDSPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.rds"),
    name: "Resource Discovery Service",
    version: SemanticVersion(1),
    capabilities: [
      PluginCapability("resource-discovery"), PluginCapability("capability-discovery"),
    ],
    requiredServices: [
      RuntimeServices.toolDiscovery.id,
      RuntimeServices.toolRegistry.id,
      RuntimeServices.toolExecution.id,
    ],
    providedServices: [
      RuntimeServices.resourceDiscovery.id,
      RuntimeServices.capabilityDiscovery.id,
    ]
  )

  public func apply(to context: PluginContext) async throws {
    let discovery = try await context.service(RuntimeServices.toolDiscovery)
    let registry = try await context.service(RuntimeServices.toolRegistry)
    let execution = try await context.service(RuntimeServices.toolExecution)

    let capabilities = CapabilityDiscoveryService { query, settings, limit in
      try await discovery.discover(query, settings, limit)
    }
    let resources = ResourceDiscoveryService(
      search: { query, limit in
        try await discovery.discover(query, .default, limit).map(Self.resource)
      },
      describe: { resourceID in
        guard
          let descriptor = try await discovery.discover(resourceID, .default, 100)
            .first(where: { $0.id == resourceID })
        else {
          throw CapabilityInvocationError.unsupportedTarget(resourceID)
        }
        return Self.resource(descriptor)
      },
      activate: { resourceID, sessionID in
        guard
          let descriptor = try await discovery.discover(resourceID, .default, 100)
            .first(where: { $0.id == resourceID })
        else {
          throw CapabilityInvocationError.unsupportedTarget(resourceID)
        }
        try await registry.activate(sessionID, [descriptor.id])
        return ActivatedResource(
          resource: Self.resource(descriptor),
          capabilityIDs: [descriptor.id],
          activatedAt: .now
        )
      },
      invoke: { resourceID, request, settings in
        guard request.capabilityID == resourceID else {
          throw CapabilityInvocationError.unsupportedTarget(request.capabilityID)
        }
        return try await execution.invoke(request, settings)
      }
    )
    try await context.provide(resources, as: RuntimeServices.resourceDiscovery)
    try await context.provide(capabilities, as: RuntimeServices.capabilityDiscovery)
  }

  private static func resource(_ capability: CapabilityDescriptor) -> ResourceDescriptor {
    ResourceDescriptor(
      id: capability.id,
      kind: capability.kind == .skill ? .skill : .capability,
      name: capability.name,
      summary: capability.summary,
      metadata: capability.metadata
    )
  }

  public init() {}
}
