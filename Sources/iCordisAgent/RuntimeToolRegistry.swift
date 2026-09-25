import Foundation
import iCordisKernel

public actor RuntimeToolRegistry {
  private var catalog: [String: CapabilityDescriptor] = [:]
  private var activatedBySession: [UUID: Set<String>] = [:]

  public init(descriptors: [CapabilityDescriptor] = []) {
    catalog = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
  }

  public func replaceCatalog(_ descriptors: [CapabilityDescriptor]) {
    catalog = Dictionary(uniqueKeysWithValues: descriptors.map { ($0.id, $0) })
    let validIDs = Set(catalog.keys)
    for sessionID in activatedBySession.keys {
      activatedBySession[sessionID]?.formIntersection(validIDs)
    }
  }

  public func registered() -> [CapabilityDescriptor] {
    catalog.values.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }

  public func search(query: String, limit: Int) -> [CapabilityDescriptor] {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return Array(registered().prefix(max(1, limit))) }
    let tokens = normalized.split { !$0.isLetter && !$0.isNumber }.map(String.init)
    let candidates = registered().compactMap { descriptor -> (CapabilityDescriptor, Int)? in
      let id = descriptor.id.lowercased()
      let name = descriptor.name.lowercased()
      let summary = descriptor.summary.lowercased()
      let keywords = descriptor.metadata["keywords"]?.stringValue?.lowercased() ?? ""
      let score = tokens.reduce(0) { total, token in
        total
          + (id.contains(token) ? 8 : 0)
          + (name.contains(token) ? 6 : 0)
          + (keywords.contains(token) ? 4 : 0)
          + (summary.contains(token) ? 2 : 0)
      }
      return score > 0 ? (descriptor, score) : nil
    }
    .sorted {
      $0.1 == $1.1
        ? $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        : $0.1 > $1.1
    }
    .map(\.0)
    return Array(candidates.prefix(max(1, limit)))
  }

  public func activate(sessionID: UUID, capabilityIDs: Set<String>) throws {
    let unknown = capabilityIDs.subtracting(catalog.keys)
    guard unknown.isEmpty else {
      throw CapabilityInvocationError.unsupportedTarget(unknown.sorted().joined(separator: ","))
    }
    activatedBySession[sessionID, default: []].formUnion(capabilityIDs)
  }

  public func deactivate(sessionID: UUID, capabilityIDs: Set<String>) {
    activatedBySession[sessionID]?.subtract(capabilityIDs)
  }

  public func activated(sessionID: UUID) -> [CapabilityDescriptor] {
    (activatedBySession[sessionID] ?? []).compactMap { catalog[$0] }
      .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
  }
}

/// Bridges model backends that support native tool callbacks into the currently
/// mounted ToolExecutionService. Registrations are leased so plugin disposal
/// removes the callback and reveals any prior provider deterministically.
public actor RuntimeCapabilityRouter: CapabilityInvoking {
  public init() {}
  private struct Entry: Sendable {
    let id: UUID
    let service: ToolExecutionService
  }

  private var entries: [Entry] = []

  public func install(_ service: ToolExecutionService) -> UUID {
    let id = UUID()
    entries.append(Entry(id: id, service: service))
    return id
  }

  public func remove(_ id: UUID) {
    entries.removeAll { $0.id == id }
  }

  public func hasProvider() -> Bool {
    !entries.isEmpty
  }

  public func executeCapability(
    _ request: CapabilityInvocationRequest,
    settings: AppSettings
  ) async throws -> CapabilityExecutionTrace {
    guard let service = entries.last?.service else {
      throw CapabilityInvocationError.unsupportedTarget(request.capabilityID)
    }
    return try await service.invoke(request, settings)
  }
}
