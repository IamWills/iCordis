import Foundation
import iCordisKernel

public enum AgentPluginsSpecification: String, Codable, CaseIterable, Sendable {
  case v1_0_0 = "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json"

  public var version: String {
    switch self {
    case .v1_0_0: "1.0.0"
    }
  }

  public var mcpSchema: String {
    switch self {
    case .v1_0_0: "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json"
    }
  }
}

public struct AgentPluginAuthor: Codable, Hashable, Sendable {
  public var name: String?
  public var email: String?
  public var url: String?

  public init(name: String? = nil, email: String? = nil, url: String? = nil) {
    self.name = name
    self.email = email
    self.url = url
  }
}

public struct AgentPluginManifest: Codable, Hashable, Sendable {
  public var schema: String
  public var name: String
  public var version: String?
  public var description: String?
  public var author: AgentPluginAuthor?
  public var homepage: String?
  public var repository: String?
  public var license: String?
  public var keywords: [String]?
  public var extensions: [String: JSONValue]?

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case name, version, description, author, homepage, repository, license, keywords, extensions
  }
}

public enum AgentPluginMCPTransport: String, Codable, Hashable, Sendable {
  case stdio
  case streamableHTTP = "streamable-http"
  case sse
}

public struct AgentPluginMCPServer: Codable, Hashable, Sendable {
  public var type: AgentPluginMCPTransport
  public var command: String?
  public var args: [String]?
  public var env: [String: String]?
  public var cwd: String?
  public var url: String?
  public var headers: [String: String]?
}

public struct AgentPluginMCPConfiguration: Codable, Hashable, Sendable {
  public var schema: String
  public var mcpServers: [String: AgentPluginMCPServer]

  enum CodingKeys: String, CodingKey {
    case schema = "$schema"
    case mcpServers
  }
}

public struct AgentPluginSkill: Hashable, Sendable {
  public var id: String
  public var name: String
  public var description: String
  public var instructions: String
  public var directory: URL

  public var descriptor: SkillDescriptor {
    SkillDescriptor(
      id: id,
      name: name,
      summary: description,
      schema: CapabilityParameterSchema(type: "object", properties: [:], required: []),
      metadata: [
        "agentPlugins": .bool(true),
        "skillDirectory": .string(directory.path),
      ],
      isEnabled: true
    )
  }
}

public struct AgentPluginPackage: Sendable {
  public var root: URL
  public var manifest: AgentPluginManifest
  public var specification: AgentPluginsSpecification
  public var skills: [AgentPluginSkill]
  public var mcp: AgentPluginMCPConfiguration?
  public var diagnostics: [String]

  public init(
    root: URL,
    manifest: AgentPluginManifest,
    specification: AgentPluginsSpecification,
    skills: [AgentPluginSkill],
    mcp: AgentPluginMCPConfiguration?,
    diagnostics: [String]
  ) {
    self.root = root
    self.manifest = manifest
    self.specification = specification
    self.skills = skills
    self.mcp = mcp
    self.diagnostics = diagnostics
  }

  public var skillDescriptors: [SkillDescriptor] { skills.map(\.descriptor) }

  public var mcpServerDescriptors: [MCPServerDescriptor] {
    guard let mcp else { return [] }
    return mcp.mcpServers.sorted { $0.key < $1.key }.map { name, server in
      MCPServerDescriptor(
        id: "agent-plugin.\(manifest.name).\(name)",
        name: name,
        transport: server.type.rawValue,
        endpoint: server.url ?? server.command,
        capabilities: [],
        isEnabled: true
      )
    }
  }

  public func extensionValue(namespace: String) -> JSONValue? {
    manifest.extensions?[namespace]
  }
}

public enum AgentPluginsError: Error, LocalizedError, Sendable, Equatable {
  case invalidRoot
  case missingManifest
  case unsupportedSchema(String)
  case invalidManifest(String)
  case invalidMCP(String)
  case packageBoundaryViolation(String)

  public var errorDescription: String? {
    switch self {
    case .invalidRoot: "Agent Plugin root must be a directory."
    case .missingManifest: "Agent Plugin is missing plugin.json."
    case .unsupportedSchema(let schema): "Unsupported Agent Plugins schema: \(schema)"
    case .invalidManifest(let detail): "Invalid Agent Plugin manifest: \(detail)"
    case .invalidMCP(let detail): "Invalid Agent Plugin MCP configuration: \(detail)"
    case .packageBoundaryViolation(let path): "Agent Plugin path escapes its package boundary: \(path)"
    }
  }
}

public struct AgentPluginsService: WilliamService {
  public let load: @Sendable (URL) async throws -> AgentPluginPackage
  public let supportedVersions: @Sendable () -> [String]

  public init(
    load: @escaping @Sendable (URL) async throws -> AgentPluginPackage,
    supportedVersions: @escaping @Sendable () -> [String]
  ) {
    self.load = load
    self.supportedVersions = supportedVersions
  }
}

public struct AgentPluginsBridgePlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("icordis.bridge.agent-plugins"),
    name: "Agent Plugins Bridge",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent-plugins"), PluginCapability("agent-plugins.1.x")],
    providedServices: [RuntimeServices.agentPlugins.id],
    permissions: [.filesystem]
  )

  private let loader: AgentPluginLoader

  public init(fileManager: FileManager = .default) {
    loader = AgentPluginLoader(fileManager: fileManager)
  }

  public func apply(to context: PluginContext) async throws {
    let loader = self.loader
    try await context.provide(
      AgentPluginsService(
        load: { url in try loader.load(root: url) },
        supportedVersions: { AgentPluginsSpecification.allCases.map(\.version) }
      ),
      as: RuntimeServices.agentPlugins
    )
  }
}

public struct AgentPluginLoader: Sendable {
  private let fileManager: FileManager
  private let decoder = JSONDecoder()

  public init(fileManager: FileManager = .default) {
    self.fileManager = fileManager
  }

  public func load(root: URL) throws -> AgentPluginPackage {
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: resolvedRoot.path, isDirectory: &isDirectory), isDirectory.boolValue else {
      throw AgentPluginsError.invalidRoot
    }

    let manifestURL = try contained(resolvedRoot.appendingPathComponent("plugin.json"), in: resolvedRoot)
    guard fileManager.fileExists(atPath: manifestURL.path) else {
      throw AgentPluginsError.missingManifest
    }

    let manifestData = try Data(contentsOf: manifestURL)
    let manifest: AgentPluginManifest
    do {
      manifest = try decoder.decode(AgentPluginManifest.self, from: manifestData)
    } catch {
      throw AgentPluginsError.invalidManifest(error.localizedDescription)
    }

    guard let specification = AgentPluginsSpecification(rawValue: manifest.schema) else {
      throw AgentPluginsError.unsupportedSchema(manifest.schema)
    }
    try validateManifest(manifest)

    var diagnostics: [String] = []
    let skills = try discoverSkills(root: resolvedRoot, pluginName: manifest.name, diagnostics: &diagnostics)
    let mcp = try loadMCP(root: resolvedRoot, specification: specification, diagnostics: &diagnostics)

    return AgentPluginPackage(
      root: resolvedRoot,
      manifest: manifest,
      specification: specification,
      skills: skills,
      mcp: mcp,
      diagnostics: diagnostics
    )
  }

  private func validateManifest(_ manifest: AgentPluginManifest) throws {
    let pattern = "^[a-z0-9](?:[a-z0-9.-]{0,62}[a-z0-9])?$"
    guard manifest.name.range(of: pattern, options: .regularExpression) != nil,
      !manifest.name.contains("--"),
      !manifest.name.contains("..")
    else {
      throw AgentPluginsError.invalidManifest("invalid name \(manifest.name)")
    }
  }

  private func discoverSkills(
    root: URL,
    pluginName: String,
    diagnostics: inout [String]
  ) throws -> [AgentPluginSkill] {
    let skillsRoot = try contained(root.appendingPathComponent("skills"), in: root)
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: skillsRoot.path, isDirectory: &isDirectory) else { return [] }
    guard isDirectory.boolValue else {
      diagnostics.append("skills exists but is not a directory; skills component ignored")
      return []
    }

    let children = try fileManager.contentsOfDirectory(
      at: skillsRoot,
      includingPropertiesForKeys: [.isDirectoryKey, .isRegularFileKey],
      options: [.skipsHiddenFiles]
    )
    var result: [AgentPluginSkill] = []
    for child in children.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      do {
        let directory = try contained(child, in: root)
        let skillURL = try contained(directory.appendingPathComponent("SKILL.md"), in: root)
        let values = try skillURL.resourceValues(forKeys: [.isRegularFileKey])
        guard values.isRegularFile == true else { continue }
        let source = try String(contentsOf: skillURL, encoding: .utf8)
        result.append(try parseSkill(source, directory: directory, pluginName: pluginName))
      } catch {
        diagnostics.append("skill \(child.lastPathComponent) ignored: \(error.localizedDescription)")
      }
    }
    return result
  }

  private func parseSkill(_ source: String, directory: URL, pluginName: String) throws -> AgentPluginSkill {
    let lines = source.components(separatedBy: .newlines)
    guard lines.first == "---", let close = lines.dropFirst().firstIndex(of: "---") else {
      throw AgentPluginsError.invalidManifest("SKILL.md requires YAML frontmatter")
    }
    var fields: [String: String] = [:]
    for line in lines[1..<close] {
      guard let separator = line.firstIndex(of: ":") else { continue }
      let key = line[..<separator].trimmingCharacters(in: .whitespaces)
      var value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespaces)
      if value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2 {
        value.removeFirst()
        value.removeLast()
      }
      fields[key] = value
    }
    let fallbackName = directory.lastPathComponent
    let name = fields["name"].flatMap { $0.isEmpty ? nil : $0 } ?? fallbackName
    let description = fields["description"] ?? ""
    let instructions = lines[lines.index(after: close)...].joined(separator: "\n")
      .trimmingCharacters(in: .whitespacesAndNewlines)
    return AgentPluginSkill(
      id: "agent-plugin.\(pluginName).skill.\(fallbackName)",
      name: name,
      description: description,
      instructions: instructions,
      directory: directory
    )
  }

  private func loadMCP(
    root: URL,
    specification: AgentPluginsSpecification,
    diagnostics: inout [String]
  ) throws -> AgentPluginMCPConfiguration? {
    let url = try contained(root.appendingPathComponent("mcp.json"), in: root)
    guard fileManager.fileExists(atPath: url.path) else { return nil }
    let config: AgentPluginMCPConfiguration
    do {
      config = try decoder.decode(AgentPluginMCPConfiguration.self, from: Data(contentsOf: url))
    } catch {
      diagnostics.append("mcp.json ignored: \(error.localizedDescription)")
      return nil
    }
    guard config.schema == specification.mcpSchema else {
      diagnostics.append("mcp.json ignored: schema does not match plugin.json")
      return nil
    }

    let valid = config.mcpServers.filter { name, server in
      switch server.type {
      case .stdio:
        guard let command = server.command, !command.isEmpty, server.url == nil else {
          diagnostics.append("MCP server \(name) ignored: invalid stdio fields")
          return false
        }
        if command.hasPrefix("./") {
          do { _ = try contained(root.appendingPathComponent(String(command.dropFirst(2))), in: root) }
          catch {
            diagnostics.append("MCP server \(name) ignored: command escapes plugin root")
            return false
          }
        }
        return true
      case .streamableHTTP, .sse:
        guard server.command == nil, let value = server.url, let remote = URL(string: value),
          ["http", "https"].contains(remote.scheme?.lowercased() ?? ""), remote.user == nil,
          remote.password == nil, remote.fragment == nil
        else {
          diagnostics.append("MCP server \(name) ignored: invalid remote URL")
          return false
        }
        if !isLoopback(remote), remote.scheme?.lowercased() != "https" {
          diagnostics.append("MCP server \(name) ignored: non-loopback remote MCP requires HTTPS")
          return false
        }
        return true
      }
    }
    return AgentPluginMCPConfiguration(schema: config.schema, mcpServers: valid)
  }

  private func isLoopback(_ url: URL) -> Bool {
    guard let host = url.host?.lowercased() else { return false }
    return host == "localhost" || host == "127.0.0.1" || host == "::1"
  }

  private func contained(_ url: URL, in root: URL) throws -> URL {
    let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL
    let resolved = url.resolvingSymlinksInPath().standardizedFileURL
    let rootPath = resolvedRoot.path.hasSuffix("/") ? resolvedRoot.path : resolvedRoot.path + "/"
    guard resolved.path == resolvedRoot.path || resolved.path.hasPrefix(rootPath) else {
      throw AgentPluginsError.packageBoundaryViolation(url.path)
    }
    return resolved
  }
}
