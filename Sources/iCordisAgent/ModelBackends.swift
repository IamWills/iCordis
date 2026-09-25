import Foundation
import iCordisKernel

/// One model backend: it declares which models it serves and runs them. Backends
/// are contributed by plugins into the `ModelBackendRegistry`, so a backend can
/// be added or removed by mounting/unmounting its plugin — the `model` slot's
/// router stays stable. This is the Cordis "scoped registry" pattern applied to
/// inference backends (previously hardcoded branches in `UnifiedInferenceRuntime`).
public struct ModelBackend: Sendable {
  /// Stable id, for diagnostics and de-duplication.
  public let id: String
  /// Whether this backend serves the given model.
  public let handles: @Sendable (LocalModelDescriptor) -> Bool
  /// The backend's inference runtime.
  public let runtime: any InferenceRuntimeProtocol

  public init(
    id: String, handles: @escaping @Sendable (LocalModelDescriptor) -> Bool,
    runtime: any InferenceRuntimeProtocol
  ) {
    self.id = id
    self.handles = handles
    self.runtime = runtime
  }
}

/// The registry service backend plugins register into and the router reads.
public struct ModelBackendRegistry: WilliamService {
  public let register: @Sendable (ModelBackend) async -> UUID
  public let remove: @Sendable (UUID) async -> Void
  public let backends: @Sendable () async -> [ModelBackend]

  public init(
    register: @escaping @Sendable (ModelBackend) async -> UUID,
    remove: @escaping @Sendable (UUID) async -> Void,
    backends: @escaping @Sendable () async -> [ModelBackend]
  ) {
    self.register = register
    self.remove = remove
    self.backends = backends
  }
}

/// Actor store backing `ModelBackendRegistry`. Registration order is preserved so
/// the router's first-match is deterministic.
public actor ModelBackendStore {
  public init() {}
  private struct Entry {
    let id: UUID
    let order: UInt64
    let backend: ModelBackend
  }
  private var entries: [Entry] = []
  private var nextOrder: UInt64 = 0

  public func register(_ backend: ModelBackend) -> UUID {
    let id = UUID()
    entries.append(Entry(id: id, order: nextOrder, backend: backend))
    nextOrder += 1
    return id
  }

  public func remove(_ id: UUID) {
    entries.removeAll { $0.id == id }
  }

  public func backends() -> [ModelBackend] {
    entries.sorted { $0.order < $1.order }.map(\.backend)
  }

  public nonisolated func service() -> ModelBackendRegistry {
    ModelBackendRegistry(
      register: { await self.register($0) },
      remove: { await self.remove($0) },
      backends: { await self.backends() }
    )
  }
}

/// Routes each request to the registered backend that handles the active model.
/// Replaces `UnifiedInferenceRuntime`'s fixed local/hosted/chat branches with a
/// registry lookup, so backends are pluggable.
public actor ModelBackendRouter: InferenceRuntimeProtocol {
  private let registry: ModelBackendRegistry
  private var activeModel: LocalModelDescriptor?

  public init(registry: ModelBackendRegistry) {
    self.registry = registry
  }

  public func activeModelID() async -> UUID? { activeModel?.id }

  public func loadModel(_ model: LocalModelDescriptor) async throws {
    let all = await registry.backends()
    guard let target = all.first(where: { $0.handles(model) }) else {
      throw InferenceError.runtimeUnavailable
    }
    // Unload the others so only one backend holds a loaded model at a time.
    for backend in all where backend.id != target.id {
      await backend.runtime.unloadModel()
    }
    try await target.runtime.loadModel(model)
    activeModel = model
  }

  public func unloadModel() async {
    activeModel = nil
    for backend in await registry.backends() {
      await backend.runtime.unloadModel()
    }
  }

  public func generate(request: AIRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
    guard let activeModel, activeModel.id == request.modelID else {
      throw InferenceError.runtimeUnavailable
    }
    guard let backend = await registry.backends().first(where: { $0.handles(activeModel) }) else {
      throw InferenceError.runtimeUnavailable
    }
    return try await backend.runtime.generate(request: request)
  }

  public func cancelGeneration(sessionID: UUID) async {
    for backend in await registry.backends() {
      await backend.runtime.cancelGeneration(sessionID: sessionID)
    }
  }
}
