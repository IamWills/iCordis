import Foundation

public protocol WilliamService: Sendable {}

public struct ServiceKey<Service: WilliamService>: Hashable, Sendable {
  public let id: ServiceID

  public init(_ id: ServiceID) {
    self.id = id
  }
}
public enum ServiceConflictPolicy: Sendable {
  case reject
  case replace
}

public struct ServiceLease: Hashable, Sendable {
  fileprivate let id: UUID
  public let serviceID: ServiceID
  public let providerPluginID: PluginID
}

public struct ServiceRegistrationSnapshot: Sendable, Equatable {
  public let serviceID: ServiceID
  public let providerPluginID: PluginID
  public let scopeID: ScopeID
  public let serviceType: String
  public let replacementDepth: Int

  public init(
    serviceID: ServiceID, providerPluginID: PluginID, scopeID: ScopeID, serviceType: String,
    replacementDepth: Int
  ) {
    self.serviceID = serviceID
    self.providerPluginID = providerPluginID
    self.scopeID = scopeID
    self.serviceType = serviceType
    self.replacementDepth = replacementDepth
  }
}

public enum ServiceRegistryError: Error, LocalizedError, Sendable, Equatable {
  case conflict(serviceID: ServiceID, existingProvider: PluginID)
  case missing(ServiceID)
  case typeMismatch(serviceID: ServiceID, expected: String, actual: String)

  public var errorDescription: String? {
    switch self {
    case .conflict(let serviceID, let provider):
      "Service \(serviceID) is already provided by \(provider)."
    case .missing(let serviceID):
      "Service \(serviceID) is unavailable."
    case .typeMismatch(let serviceID, let expected, let actual):
      "Service \(serviceID) expected \(expected), but registry contains \(actual)."
    }
  }
}

public actor ServiceRegistry {
  public init() {}
  private struct Entry: Sendable {
    let lease: ServiceLease
    let scopeID: ScopeID
    let serviceType: String
    let value: any WilliamService
  }

  private var entries: [ServiceID: [Entry]] = [:]

  public func provide<Service: WilliamService>(
    _ service: Service,
    for key: ServiceKey<Service>,
    provider: PluginID,
    scopeID: ScopeID,
    conflictPolicy: ServiceConflictPolicy = .reject
  ) throws -> ServiceLease {
    let existing = entries[key.id] ?? []
    if let current = existing.last, conflictPolicy == .reject {
      throw ServiceRegistryError.conflict(
        serviceID: key.id,
        existingProvider: current.lease.providerPluginID
      )
    }
    let lease = ServiceLease(id: UUID(), serviceID: key.id, providerPluginID: provider)
    let entry = Entry(
      lease: lease,
      scopeID: scopeID,
      serviceType: String(reflecting: Service.self),
      value: service
    )
    entries[key.id, default: []].append(entry)
    return lease
  }

  public func resolve<Service: WilliamService>(_ key: ServiceKey<Service>) throws -> Service {
    guard let entry = entries[key.id]?.last else {
      throw ServiceRegistryError.missing(key.id)
    }
    guard let service = entry.value as? Service else {
      throw ServiceRegistryError.typeMismatch(
        serviceID: key.id,
        expected: String(reflecting: Service.self),
        actual: entry.serviceType
      )
    }
    return service
  }

  public func optional<Service: WilliamService>(_ key: ServiceKey<Service>) throws -> Service? {
    guard entries[key.id]?.isEmpty == false else { return nil }
    return try resolve(key)
  }

  public func contains(_ serviceID: ServiceID) -> Bool {
    entries[serviceID]?.isEmpty == false
  }

  public func currentProvider(for serviceID: ServiceID) -> PluginID? {
    entries[serviceID]?.last?.lease.providerPluginID
  }

  public func remove(_ lease: ServiceLease) {
    guard var stack = entries[lease.serviceID] else { return }
    stack.removeAll { $0.lease == lease }
    if stack.isEmpty {
      entries.removeValue(forKey: lease.serviceID)
    } else {
      entries[lease.serviceID] = stack
    }
  }

  public func snapshots() -> [ServiceRegistrationSnapshot] {
    entries.flatMap { serviceID, stack in
      stack.enumerated().map { index, entry in
        ServiceRegistrationSnapshot(
          serviceID: serviceID,
          providerPluginID: entry.lease.providerPluginID,
          scopeID: entry.scopeID,
          serviceType: entry.serviceType,
          replacementDepth: index
        )
      }
    }
    .sorted {
      if $0.serviceID.rawValue == $1.serviceID.rawValue {
        return $0.replacementDepth < $1.replacementDepth
      }
      return $0.serviceID.rawValue < $1.serviceID.rawValue
    }
  }
}
