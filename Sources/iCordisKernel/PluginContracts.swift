import Foundation

public struct PluginID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}
public struct ServiceID: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public var description: String { rawValue }
}

public struct PluginCapability: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

public struct PluginPermission: RawRepresentable, Codable, Hashable, Sendable {
  public let rawValue: String

  public init(rawValue: String) {
    self.rawValue = rawValue
  }

  public init(_ rawValue: String) {
    self.rawValue = rawValue
  }

  public static let network = PluginPermission("network")
  public static let filesystemRead = PluginPermission("filesystem.read")
  public static let filesystemWrite = PluginPermission("filesystem.write")
  public static let process = PluginPermission("process")
  public static let shell = PluginPermission("shell")
  public static let transaction = PluginPermission("transaction")
}

public struct SemanticVersion: Codable, Hashable, Comparable, Sendable, CustomStringConvertible {
  public let major: Int
  public let minor: Int
  public let patch: Int

  public init(_ major: Int, _ minor: Int = 0, _ patch: Int = 0) {
    precondition(major >= 0 && minor >= 0 && patch >= 0)
    self.major = major
    self.minor = minor
    self.patch = patch
  }

  public var description: String { "\(major).\(minor).\(patch)" }

  public static func < (lhs: SemanticVersion, rhs: SemanticVersion) -> Bool {
    (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
  }
}

public enum PluginVersionRequirement: Codable, Hashable, Sendable {
  case any
  case exact(SemanticVersion)
  case atLeast(SemanticVersion)
  case compatibleWithMajor(SemanticVersion)

  public func accepts(_ version: SemanticVersion) -> Bool {
    switch self {
    case .any:
      true
    case .exact(let expected):
      version == expected
    case .atLeast(let minimum):
      version >= minimum
    case .compatibleWithMajor(let minimum):
      version.major == minimum.major && version >= minimum
    }
  }
}

public struct PluginDependency: Codable, Hashable, Sendable {
  public let id: PluginID
  public let version: PluginVersionRequirement

  public init(id: PluginID, version: PluginVersionRequirement = .any) {
    self.id = id
    self.version = version
  }
}

public enum WilliamPlatform: String, Codable, Hashable, Sendable {
  case iOS
  case macOS
  case visionOS

  public static var current: WilliamPlatform {
    #if os(iOS)
      .iOS
    #elseif os(macOS)
      .macOS
    #elseif os(visionOS)
      .visionOS
    #else
      #error("WilliamKernel supports Apple platforms only")
    #endif
  }
}

public enum PluginOrigin: String, Codable, Hashable, Sendable {
  case builtIn
  case localDevelopment
  case remote
  case community
  case generated
}

public struct PluginManifest: Codable, Hashable, Sendable {
  public let id: PluginID
  public let name: String
  public let version: SemanticVersion
  public let origin: PluginOrigin
  public let capabilities: Set<PluginCapability>
  public let dependencies: [PluginDependency]
  public let optionalDependencies: [PluginDependency]
  public let requiredServices: Set<ServiceID>
  public let optionalServices: Set<ServiceID>
  public let providedServices: Set<ServiceID>
  public let supportedPlatforms: Set<WilliamPlatform>
  public let permissions: Set<PluginPermission>

  public init(
    id: PluginID,
    name: String,
    version: SemanticVersion,
    origin: PluginOrigin = .builtIn,
    capabilities: Set<PluginCapability> = [],
    dependencies: [PluginDependency] = [],
    optionalDependencies: [PluginDependency] = [],
    requiredServices: Set<ServiceID> = [],
    optionalServices: Set<ServiceID> = [],
    providedServices: Set<ServiceID> = [],
    supportedPlatforms: Set<WilliamPlatform> = [.iOS, .macOS, .visionOS],
    permissions: Set<PluginPermission> = []
  ) {
    self.id = id
    self.name = name
    self.version = version
    self.origin = origin
    self.capabilities = capabilities
    self.dependencies = dependencies
    self.optionalDependencies = optionalDependencies
    self.requiredServices = requiredServices
    self.optionalServices = optionalServices
    self.providedServices = providedServices
    self.supportedPlatforms = supportedPlatforms
    self.permissions = permissions
  }
}

public protocol WilliamPlugin: Sendable {
  static var manifest: PluginManifest { get }
  var manifest: PluginManifest { get }

  func apply(to context: PluginContext) async throws
}

extension WilliamPlugin {
  public var manifest: PluginManifest { Self.manifest }
}

public enum PluginContractError: Error, LocalizedError, Sendable, Equatable {
  case invalidManifest(pluginID: PluginID, reason: String)
  case unsupportedPlatform(pluginID: PluginID, platform: WilliamPlatform)
  case duplicatePlugin(PluginID)
  case pluginNotMounted(PluginID)
  case advertisedServiceMissing(pluginID: PluginID, serviceID: ServiceID)

  public var errorDescription: String? {
    switch self {
    case .invalidManifest(let pluginID, let reason):
      "Plugin \(pluginID) has an invalid manifest: \(reason)"
    case .unsupportedPlatform(let pluginID, let platform):
      "Plugin \(pluginID) does not support \(platform.rawValue)."
    case .duplicatePlugin(let pluginID):
      "Plugin \(pluginID) is already mounted."
    case .pluginNotMounted(let pluginID):
      "Plugin \(pluginID) is not mounted."
    case .advertisedServiceMissing(let pluginID, let serviceID):
      "Plugin \(pluginID) did not provide advertised service \(serviceID)."
    }
  }
}
