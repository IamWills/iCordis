import Foundation
import iCordisKernel

public struct MolobayaPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.molobaya"),
    name: "Molobaya",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("delegation"), PluginCapability("business-action")],
    dependencies: [PluginDependency(id: SafeApprovalPlugin.manifest.id)],
    requiredServices: [RuntimeServices.approval.id, RuntimeServices.transaction.id],
    providedServices: [RuntimeServices.delegation.id],
    permissions: [.transaction]
  )

  public func apply(to context: PluginContext) async throws {
    let approval = try await context.service(RuntimeServices.approval)
    let transaction = try await context.service(RuntimeServices.transaction)
    let pluginID = Self.manifest.id
    let delegation = DelegationService { request in
      let decision = await approval.request(
        BusinessApprovalRequest(
          id: UUID(),
          pluginID: pluginID,
          title: "Delegate capability",
          summary: request.objective,
          payload: request.payload
        ))
      return .object([
        "delegationID": .string(request.id.uuidString),
        "capabilityID": .string(request.capabilityID),
        "status": .string(decision.rawValue),
        "executed": .bool(false),
        "transactionServiceAvailable": .bool(true),
      ])
    }
    _ = transaction
    try await context.provide(delegation, as: RuntimeServices.delegation)
  }

  public init() {}
}
