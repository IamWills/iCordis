import Foundation
import iCordisKernel

/// Provides the `ModelBackendRegistry` so backend plugins have somewhere to
/// register and the router has something to read. The store is created by the
/// composition root and shared with the router, so registrations made through
/// this service are visible to the live `model` slot.
public struct ModelBackendRegistryPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.model-backends"),
    name: "Model Backend Registry",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("model-backends")],
    providedServices: [RuntimeServices.modelBackends.id]
  )

  public let registry: ModelBackendRegistry

  public func apply(to context: PluginContext) async throws {
    try await context.provide(registry, as: RuntimeServices.modelBackends)
  }

  public init(registry: ModelBackendRegistry) { self.registry = registry }
}

/// Contributes one inference backend into the registry. Instantiated once per
/// backend (local, hosted-responses, chat-completions); each carries a distinct
/// instance manifest id so the kernel mounts them as separate, independently
/// unmountable plugins. Unmounting one removes its backend via a reversible
/// effect, and the router simply stops routing to it — no code change.
public struct ModelBackendPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.model-backend"),
    name: "Model Backend",
    version: SemanticVersion(1),
    requiredServices: [RuntimeServices.modelBackends.id]
  )

  public let backend: ModelBackend

  public var manifest: PluginManifest {
    PluginManifest(
      id: PluginID("william.model-backend.\(backend.id)"),
      name: "Model Backend: \(backend.id)",
      version: SemanticVersion(1),
      capabilities: [PluginCapability("model-backend.\(backend.id)")],
      requiredServices: [RuntimeServices.modelBackends.id]
    )
  }

  public func apply(to context: PluginContext) async throws {
    let registry = try await context.service(RuntimeServices.modelBackends)
    let id = await registry.register(backend)
    try await context.effect(label: "model-backend:\(backend.id)") {
      await registry.remove(id)
    }
  }

  public init(backend: ModelBackend) { self.backend = backend }
}

/// Contributes one tool provider into the registry. This is the vehicle for
/// peeling a group of tools off the monolithic builtin registry: give the group
/// its own provider and mount it as this plugin (dropping the group's descriptors
/// and dispatch case from the builtin registry). Instantiated once per group,
/// each with a distinct instance manifest id, and unmounting removes the group
/// via a reversible effect.
public struct ToolProviderPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.tool-provider"),
    name: "Tool Provider",
    version: SemanticVersion(1),
    requiredServices: [RuntimeServices.toolProviders.id]
  )

  public let provider: ToolProvider

  public var manifest: PluginManifest {
    PluginManifest(
      id: PluginID("william.tool-provider.\(provider.id)"),
      name: "Tool Provider: \(provider.id)",
      version: SemanticVersion(1),
      capabilities: [PluginCapability("tool-provider.\(provider.id)")],
      requiredServices: [RuntimeServices.toolProviders.id]
    )
  }

  public func apply(to context: PluginContext) async throws {
    let registry = try await context.service(RuntimeServices.toolProviders)
    let id = await registry.register(provider)
    try await context.effect(label: "tool-provider:\(provider.id)") {
      await registry.remove(id)
    }
  }

  public init(provider: ToolProvider) { self.provider = provider }
}

extension ModelBackend {
  /// On-device models (MLX/GGUF/LiteRT) — anything not a hosted `.responsesAPI`.
  public static func local(_ runtime: any InferenceRuntimeProtocol) -> ModelBackend {
    ModelBackend(id: "local", handles: { $0.format != .responsesAPI }, runtime: runtime)
  }

  /// Hosted ResponsesAI envelope models.
  public static func hostedResponses(_ runtime: any InferenceRuntimeProtocol) -> ModelBackend {
    ModelBackend(
      id: "hosted-responses",
      handles: { $0.format == .responsesAPI && !HostedResponsesModel.isChatCompletions($0) },
      runtime: runtime
    )
  }

  /// OpenAI-compatible chat-completions models (route B).
  public static func chatCompletions(_ runtime: any InferenceRuntimeProtocol) -> ModelBackend {
    ModelBackend(
      id: "chat-completions",
      handles: { $0.format == .responsesAPI && HostedResponsesModel.isChatCompletions($0) },
      runtime: runtime
    )
  }
}
