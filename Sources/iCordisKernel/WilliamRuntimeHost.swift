import Foundation

public struct WilliamPreset: Sendable {
  public let id: String
  public let name: String
  public let plugins: [any WilliamPlugin]

  public init(id: String, name: String, plugins: [any WilliamPlugin]) {
    self.id = id
    self.name = name
    self.plugins = plugins
  }
}

public actor WilliamRuntimeHost {
  public nonisolated let kernel: WilliamKernel
  public nonisolated let preset: WilliamPreset

  private var startTask: Task<Void, Error>?

  public init(kernel: WilliamKernel = WilliamKernel(), preset: WilliamPreset) {
    self.kernel = kernel
    self.preset = preset
  }

  public func start() async throws {
    let task: Task<Void, Error>
    if let startTask {
      task = startTask
    } else {
      let kernel = self.kernel
      let plugins = preset.plugins
      let created = Task {
        do {
          for plugin in plugins {
            _ = try await kernel.mount(plugin)
          }
          let unresolved = await kernel.diagnostics().plugins.filter { $0.state == .unresolved }
          guard unresolved.isEmpty else {
            let detail = unresolved.map {
              "\($0.manifest.id): plugins=\($0.missingPlugins.map(\.rawValue).sorted()) services=\($0.missingServices.map(\.rawValue).sorted())"
            }.joined(separator: "; ")
            throw WilliamRuntimeHostError.unresolvedPlugins(detail)
          }
        } catch {
          try? await kernel.shutdown()
          throw error
        }
      }
      startTask = created
      task = created
    }
    try await task.value
  }

  public func service<Service: WilliamService>(_ key: ServiceKey<Service>) async throws -> Service {
    try await start()
    return try await kernel.services.resolve(key)
  }

  public func diagnostics() async -> KernelDiagnosticsSnapshot {
    await kernel.diagnostics()
  }

  public func shutdown() async throws {
    if let startTask {
      _ = try? await startTask.value
    }
    try await kernel.shutdown()
    startTask = nil
  }
}

public enum WilliamRuntimeHostError: Error, LocalizedError, Sendable, Equatable {
  case unresolvedPlugins(String)

  public var errorDescription: String? {
    switch self {
    case .unresolvedPlugins(let detail):
      "William preset contains unresolved plugins: \(detail)"
    }
  }
}
