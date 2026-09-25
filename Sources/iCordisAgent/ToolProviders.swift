import Foundation
import iCordisKernel

/// One tool provider: it contributes capability descriptors and runs the
/// capabilities it owns. Providers are contributed into the `ToolProviderRegistry`
/// so a group of tools can be added or removed by mounting/unmounting a plugin —
/// the native dispatch no longer hardcodes a prefix if-chain. This is the Cordis
/// "scoped registry" pattern applied to the tool surface, the seam for peeling
/// groups off the monolithic builtin registry one at a time.
public struct ToolProvider: Sendable {
  /// Stable id, for diagnostics and ordering.
  public let id: String
  /// The descriptors this provider contributes under the given settings.
  public let descriptors: @Sendable (AppSettings) async throws -> [CapabilityDescriptor]
  /// Whether this provider runs the given capability id.
  public let handles: @Sendable (String) -> Bool
  /// Runs one capability this provider owns.
  public let invoke:
    @Sendable (CapabilityInvocationRequest, AppSettings) async throws -> CapabilityInvocationResult

  public init(
    id: String,
    descriptors: @escaping @Sendable (AppSettings) async throws -> [CapabilityDescriptor],
    handles: @escaping @Sendable (String) -> Bool,
    invoke:
      @escaping @Sendable (CapabilityInvocationRequest, AppSettings) async throws ->
      CapabilityInvocationResult
  ) {
    self.id = id
    self.descriptors = descriptors
    self.handles = handles
    self.invoke = invoke
  }
}

/// The registry service tool-provider plugins register into and the native tool
/// dispatch reads.
public struct ToolProviderRegistry: WilliamService {
  public let register: @Sendable (ToolProvider) async -> UUID
  public let remove: @Sendable (UUID) async -> Void
  public let providers: @Sendable () async -> [ToolProvider]

  public init(
    register: @escaping @Sendable (ToolProvider) async -> UUID,
    remove: @escaping @Sendable (UUID) async -> Void,
    providers: @escaping @Sendable () async -> [ToolProvider]
  ) {
    self.register = register
    self.remove = remove
    self.providers = providers
  }
}

/// Actor store backing `ToolProviderRegistry`. Registration order is preserved so
/// descriptor aggregation and first-match dispatch are deterministic.
public actor ToolProviderStore {
  public init() {}
  private struct Entry {
    let id: UUID
    let order: UInt64
    let provider: ToolProvider
  }
  private var entries: [Entry] = []
  private var nextOrder: UInt64 = 0

  public func register(_ provider: ToolProvider) -> UUID {
    let id = UUID()
    entries.append(Entry(id: id, order: nextOrder, provider: provider))
    nextOrder += 1
    return id
  }

  public func remove(_ id: UUID) {
    entries.removeAll { $0.id == id }
  }

  public func providers() -> [ToolProvider] {
    entries.sorted { $0.order < $1.order }.map(\.provider)
  }

  public nonisolated func service() -> ToolProviderRegistry {
    ToolProviderRegistry(
      register: { await self.register($0) },
      remove: { await self.remove($0) },
      providers: { await self.providers() }
    )
  }

  /// Aggregate every provider's descriptors for the given settings, name-sorted.
  public func descriptors(settings: AppSettings) async throws -> [CapabilityDescriptor] {
    var values: [CapabilityDescriptor] = []
    for provider in providers() {
      values.append(contentsOf: try await provider.descriptors(settings))
    }
    return values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  /// The first provider that handles the capability, or nil.
  public func provider(for capabilityID: String) -> ToolProvider? {
    providers().first { $0.handles(capabilityID) }
  }
}
