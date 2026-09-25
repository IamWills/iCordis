import Foundation
import iCordisKernel

/// Typed tool discovery and execution middleware, independent of concrete tool providers.
public struct ToolRuntimePlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("icordis.tools.runtime"), name: "Tool Runtime", version: SemanticVersion(1),
    requiredServices: [RuntimeServices.permission.id],
    providedServices: [
      RuntimeServices.toolCatalog.id, RuntimeServices.toolDiscovery.id,
      RuntimeServices.toolRegistry.id, RuntimeServices.toolExecution.id,
      RuntimeServices.toolProviders.id,
    ]
  )
  public let providers: ToolProviderStore
  public let registry: RuntimeToolRegistry
  public let runtimeRouter: RuntimeCapabilityRouter?
  /// Set only when every provider implements its own ask-user approval flow.
  public let providersHandleApproval: Bool
  public init(
    providers: ToolProviderStore = ToolProviderStore(),
    registry: RuntimeToolRegistry = RuntimeToolRegistry(),
    runtimeRouter: RuntimeCapabilityRouter? = nil, providersHandleApproval: Bool = false
  ) {
    self.providers = providers
    self.registry = registry
    self.runtimeRouter = runtimeRouter
    self.providersHandleApproval = providersHandleApproval
  }
  public func apply(to context: PluginContext) async throws {
    let permission = try await context.service(RuntimeServices.permission)
    let providerStore = providers
    let owner = context.pluginID
    let descriptors: @Sendable (AppSettings) async throws -> [CapabilityDescriptor] = { settings in
      try await providerStore.descriptors(settings: settings)
    }
    let catalog = ToolCatalogService {
      let values = try await descriptors(.default)
      await registry.replaceCatalog(values)
      return values
    }
    let discovery = ToolDiscoveryService { query, settings, limit in
      let values = try await descriptors(settings)
      await registry.replaceCatalog(values)
      return await registry.search(query: query, limit: limit)
    }
    let toolRegistry = ToolRegistryService(
      registered: {
        let values = try await descriptors(.default)
        await registry.replaceCatalog(values)
        return await registry.registered()
      },
      activated: { await registry.activated(sessionID: $0) },
      activate: { try await registry.activate(sessionID: $0, capabilityIDs: $1) },
      deactivate: { await registry.deactivate(sessionID: $0, capabilityIDs: $1) }
    )
    // Tool execution runs through the Cordis waterfall: `tools/pre-execute`
    // transforms/vetoes the request, `tools/execute` wraps the invocation
    // (its terminal is the real dispatch below), and `tools/post-execute`
    // observes the trace. With no plugin handlers registered these are
    // zero-overhead pass-throughs, but any plugin can now intercept the
    // pipeline (caching, sandboxing, redaction, metrics) without touching the
    // dispatch or the builtin registry.
    let events = context.events
    let execution = ToolExecutionService(
      invoke: { request, settings in
        let perform:
          @Sendable (CapabilityInvocationRequest) async throws -> CapabilityExecutionTrace = {
            request in
            let startedAt = Date()
            let decision = await permission.evaluate(
              PermissionRequest(
                id: UUID(),
                pluginID: owner,
                kind: .externalAction,
                resource: request.capabilityID,
                reason: "Execute an activated tool capability."
              ))
            guard decision == .allow || (decision == .askUser && providersHandleApproval) else {
              throw ToolPermissionError.denied(request.capabilityID)
            }
            // `askUser` is delegated to the tool's approval UI. Permission
            // and business approval remain distinct decisions. Route to the
            // provider that owns the capability.
            guard let provider = await providerStore.provider(for: request.capabilityID) else {
              throw CapabilityInvocationError.unsupportedTarget(request.capabilityID)
            }
            let result = try await provider.invoke(request, settings)
            return CapabilityExecutionTrace(
              id: UUID(),
              request: request,
              result: result,
              startedAt: startedAt,
              finishedAt: .now
            )
          }
        let shapedRequest = try await events.middleware(
          RuntimeEvents.toolsPreExecute, request: request, terminal: { $0 }
        )
        let trace = try await events.middleware(
          RuntimeEvents.toolsExecute, request: shapedRequest, terminal: perform
        )
        try? await events.emit(RuntimeEvents.toolsPostExecute, payload: trace)
        return trace
      },
      parseInlineInvocation: { Self.parseInlineInvocation(from: $0, sessionID: $1) }
    )
    try await context.provide(providerStore.service(), as: RuntimeServices.toolProviders)
    try await context.provide(catalog, as: RuntimeServices.toolCatalog)
    try await context.provide(discovery, as: RuntimeServices.toolDiscovery)
    try await context.provide(toolRegistry, as: RuntimeServices.toolRegistry)
    try await context.provide(execution, as: RuntimeServices.toolExecution)
    if let runtimeRouter {
      let lease = await runtimeRouter.install(execution)
      try await context.effect(label: "tool-runtime-router") {
        await runtimeRouter.remove(lease)
      }
    }
  }

  private static func parseInlineInvocation(
    from text: String,
    sessionID: UUID
  ) -> CapabilityInvocationRequest? {
    let components = text.trimmingCharacters(in: .whitespacesAndNewlines)
      .split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
    guard components.count >= 2 else { return nil }
    let channel = String(components[0])
    let payload = components.count == 3 ? String(components[2]) : ""
    var arguments: [String: JSONValue] = [:]
    if !payload.isEmpty {
      arguments["text"] = .string(payload)
      arguments["topic"] = .string(payload)
    }
    switch channel {
    case "/mcp":
      arguments["_server"] = .string("local.system")
      return CapabilityInvocationRequest(
        sessionID: sessionID,
        capabilityID: "mcp.system.inspect",
        arguments: arguments,
        initiatedBy: .user,
        timeout: 8
      )
    case "/skill":
      return CapabilityInvocationRequest(
        sessionID: sessionID,
        capabilityID: "skill.summarize",
        arguments: arguments,
        initiatedBy: .user,
        timeout: 8
      )
    default:
      return nil
    }
  }
}
