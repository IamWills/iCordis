import Foundation
import iCordisKernel

/// Identifies a group of tools the model can open as a unit.
///
/// String-backed rather than a closed enum because the tool population is not
/// closed: every connected MCP server contributes its own group, and that is
/// where a catalog grows from dozens of tools to hundreds.
public struct AgentToolGroupID: Hashable, Sendable, Comparable {
  public let rawValue: String

  public init(_ rawValue: String) {
    self.rawValue = rawValue.lowercased().replacingOccurrences(of: "-", with: "_")
  }

  public static func < (lhs: AgentToolGroupID, rhs: AgentToolGroupID) -> Bool {
    lhs.rawValue < rhs.rawValue
  }

  public static let core = AgentToolGroupID("core")
  public static let web = AgentToolGroupID("web")
  public static let files = AgentToolGroupID("files")
  public static let sandbox = AgentToolGroupID("sandbox")
  public static let code = AgentToolGroupID("code")
  /// Operations on Apps that are already registered. These do not require a
  /// session workspace and must remain discoverable from a plain chat.
  public static let appRuntime = AgentToolGroupID("app_runtime")
  public static let apps = AgentToolGroupID("apps")
  public static let appUI = AgentToolGroupID("app_ui")
  public static let memory = AgentToolGroupID("memory")
  public static let skills = AgentToolGroupID("skills")
  public static let session = AgentToolGroupID("session")
  /// Installed local Skills (`skill.*`).
  public static let localSkills = AgentToolGroupID("local_skills")
  public static let plugins = AgentToolGroupID("plugins")

  public static func mcpServer(_ serverID: String) -> AgentToolGroupID {
    AgentToolGroupID("mcp_" + serverID)
  }

  public static func plugin(_ pluginID: String) -> AgentToolGroupID {
    AgentToolGroupID("plugin_" + pluginID)
  }

  public var isBuiltin: Bool { Self.builtinSummaries[self] != nil }

  public var builtinSummary: String? { Self.builtinSummaries[self] }

  private static let builtinSummaries: [AgentToolGroupID: String] = [
    .core: "Tool discovery, group activation, and native user prompts.",
    .web: "Fetch and extract web pages, APIs, and feeds.",
    .files: "Read, write, list, and stat files under authorized roots.",
    .sandbox:
      "Run short throwaway Python/TypeScript/JavaScript, optionally calling other William tools from the script.",
    .code: "Search, read, and edit code in the session workspace; snapshot and diff it.",
    .appRuntime: "List and open Apps that are already registered in William's App channel.",
    .apps: "Register Apps and run build/test/dev commands in the session workspace.",
    .appUI: "Inspect and drive a running App's UI semantically, screenshot it, and run UI tests.",
    .memory: "Search, list, save, update, and forget long-term memories.",
    .skills: "Create and maintain reusable Instruction Skills.",
    .session: "Inspect conversations, sessions, models, runtime, and settings.",
    .localSkills: "Small scripted skills installed in William.",
    .plugins: "Validate, install, manage, and invoke William Plugins.",
  ]

  /// Groups whose builtin membership is fixed. Used by the test that fails
  /// when a new builtin is added without being classified.
  public static var builtinGroupIDs: Set<AgentToolGroupID> { Set(builtinSummaries.keys) }
}

/// Precomputed descriptor→group and group→membership indexes.
///
/// Built once per run. At a few dozen tools the naive scans this replaces were
/// free; at a few hundred, recomputing group membership on every turn is not.
public struct AgentToolGroupCatalog: Sendable {
  private let groupByToolID: [String: AgentToolGroupID]
  private let toolIDsByGroup: [AgentToolGroupID: [String]]
  private let summaries: [AgentToolGroupID: String]

  public init(descriptors: [CapabilityDescriptor]) {
    var groupByToolID: [String: AgentToolGroupID] = [:]
    var toolIDsByGroup: [AgentToolGroupID: [String]] = [:]
    var summaries: [AgentToolGroupID: String] = [:]

    for descriptor in descriptors {
      let group = Self.group(for: descriptor)
      groupByToolID[descriptor.id] = group
      toolIDsByGroup[group, default: []].append(descriptor.id)
      if summaries[group] == nil {
        summaries[group] = group.builtinSummary ?? Self.externalSummary(for: descriptor)
      }
    }

    self.groupByToolID = groupByToolID
    self.toolIDsByGroup = toolIDsByGroup.mapValues { $0.sorted() }
    self.summaries = summaries
  }

  public func group(forToolID id: String) -> AgentToolGroupID? { groupByToolID[id] }

  public func toolIDs(in group: AgentToolGroupID) -> [String] { toolIDsByGroup[group] ?? [] }

  public func toolCount(in group: AgentToolGroupID) -> Int { toolIDsByGroup[group]?.count ?? 0 }

  public func summary(for group: AgentToolGroupID) -> String {
    summaries[group] ?? "Tools provided by \(group.rawValue)."
  }

  public var allGroups: [AgentToolGroupID] { toolIDsByGroup.keys.sorted() }

  /// External groups exist only because something is connected, so they are
  /// discovered from the descriptors rather than declared up front.
  public var externalGroups: [AgentToolGroupID] {
    allGroups.filter { !$0.isBuiltin }
  }

  private static func externalSummary(for descriptor: CapabilityDescriptor) -> String {
    if let pluginID = descriptor.metadata["pluginID"]?.stringValue {
      return "Tools supplied by the installed William Plugin `\(pluginID)`."
    }
    if let serverID = descriptor.metadata["serverID"]?.stringValue {
      return "Tools from the connected MCP server `\(serverID)`."
    }
    return "Installed Skill tools."
  }

  private static func group(for descriptor: CapabilityDescriptor) -> AgentToolGroupID {
    if let builtin = builtinGroups[descriptor.id] { return builtin }
    if descriptor.metadata["pluginAdministration"]?.pluginBoolValue == true { return .plugins }
    if let serverID = descriptor.metadata["serverID"]?.stringValue, !serverID.isEmpty {
      return .mcpServer(serverID)
    }
    if let pluginID = descriptor.metadata["pluginID"]?.stringValue, !pluginID.isEmpty {
      return .plugin(pluginID)
    }
    if descriptor.kind == .skill || descriptor.id.hasPrefix("skill.") { return .localSkills }
    return .session
  }

  /// IDs are the source of truth so a new builtin cannot silently land in a
  /// group it does not belong to — `everyBuiltinToolIsAssignedToAGroup` fails
  /// if a builtin is missing here.
  public static let builtinGroups: [String: AgentToolGroupID] = [
    AgentBuiltinToolID.searchTools: .core,
    AgentBuiltinToolID.activateToolGroup: .core,
    AgentBuiltinToolID.requestLocalAppAction: .core,

    AgentBuiltinToolID.networkAccess: .web,
    AgentBuiltinToolID.fileSystem: .files,
    AgentBuiltinToolID.runCode: .sandbox,

    AgentBuiltinToolID.inspectCodeWorkspace: .code,
    AgentBuiltinToolID.listCodeWorkspaces: .code,
    AgentBuiltinToolID.searchCode: .code,
    AgentBuiltinToolID.snapshotCodeWorkspace: .code,
    AgentBuiltinToolID.diffCodeWorkspace: .code,
    AgentBuiltinToolID.incrementalWriteCode: .code,
    AgentBuiltinToolID.listCodeFiles: .code,
    AgentBuiltinToolID.readCodeFile: .code,
    AgentBuiltinToolID.replaceCodeText: .code,

    AgentBuiltinToolID.registerApp: .apps,
    AgentBuiltinToolID.listApps: .appRuntime,
    AgentBuiltinToolID.openApp: .appRuntime,
    AgentBuiltinToolID.runAppCommand: .apps,

    AgentBuiltinToolID.inspectAppUI: .appUI,
    AgentBuiltinToolID.actOnAppUI: .appUI,
    AgentBuiltinToolID.waitForAppUI: .appUI,
    AgentBuiltinToolID.screenshotAppUI: .appUI,
    AgentBuiltinToolID.runAppUITest: .appUI,

    AgentBuiltinToolID.searchMemory: .memory,
    AgentBuiltinToolID.listMemories: .memory,
    AgentBuiltinToolID.remember: .memory,
    AgentBuiltinToolID.updateMemory: .memory,
    AgentBuiltinToolID.forgetMemory: .memory,

    AgentBuiltinToolID.createSkill: .skills,
    AgentBuiltinToolID.loadInstructionReference: .skills,
    AgentBuiltinToolID.createInstructionSkill: .skills,
    AgentBuiltinToolID.updateInstructionSkill: .skills,
    AgentBuiltinToolID.searchInstructionSkills: .skills,
    AgentBuiltinToolID.validateInstructionSkill: .skills,
    AgentBuiltinToolID.disableInstructionSkill: .skills,

    AgentBuiltinToolID.inspectSession: .session,
    AgentBuiltinToolID.renameSession: .session,
    AgentBuiltinToolID.listSessions: .session,
    AgentBuiltinToolID.searchConversation: .session,
    AgentBuiltinToolID.listModels: .session,
    AgentBuiltinToolID.setSessionModel: .session,
    AgentBuiltinToolID.inspectRuntime: .session,
    AgentBuiltinToolID.inspectSettings: .session,

    AgentBuiltinToolID.inspectKernelPlugins: .plugins,
    AgentBuiltinToolID.kernelPluginLifecycle: .plugins,
    AgentBuiltinToolID.authorKernelPlugin: .plugins,
    AgentBuiltinToolID.communityPlugins: .plugins,
  ]
}

/// Which groups a run may use at all.
///
/// `preActivated` identifies a deliberately small control plane that is
/// declared alongside `william.tools.search` at run start. Ordinary capability
/// groups still grow from search results, but essential extension-management
/// tools must not look unavailable merely because discovery has not run yet.
public struct AgentToolAvailability: Sendable {
  public let eligible: Set<AgentToolGroupID>
  public let preActivated: Set<AgentToolGroupID>
  /// True when groups discovered from connected servers should also be
  /// eligible. They are never pre-activated.
  public let allowsExternalGroups: Bool

  public init(
    eligible: Set<AgentToolGroupID>,
    preActivated: Set<AgentToolGroupID>,
    allowsExternalGroups: Bool = true
  ) {
    self.eligible = eligible
    self.preActivated = preActivated
    self.allowsExternalGroups = allowsExternalGroups
  }

  public static let unrestricted = AgentToolAvailability(
    eligible: AgentToolGroupID.builtinGroupIDs,
    preActivated: []
  )

  public func isEligible(_ group: AgentToolGroupID) -> Bool {
    if eligible.contains(group) { return true }
    return allowsExternalGroups && !group.isBuiltin
  }

  public static func resolve(
    session: ConversationSession,
    settings: AppSettings,
    hasRegisteredApps: Bool
  ) -> AgentToolAvailability {
    var eligible: Set<AgentToolGroupID> = [
      .core, .web, .files, .sandbox, .session, .localSkills, .appRuntime, .plugins,
    ]
    // Plugin administration, local files, and the folder picker are the
    // control plane a Plugin/App run needs before discovery. Installed
    // `plugin.*` groups remain on-demand.
    let preActivated: Set<AgentToolGroupID> = [.plugins, .files, .core]

    let hasWorkingDirectory = session.workingDirectory != nil
    if hasWorkingDirectory {
      eligible.formUnion([.code, .apps, .appUI])
    }
    if hasRegisteredApps {
      eligible.insert(.appUI)
    }
    if settings.enableSkills {
      eligible.insert(.skills)
    }
    if settings.enableLongTermMemory {
      eligible.insert(.memory)
    }

    return AgentToolAvailability(
      eligible: eligible,
      preActivated: preActivated.intersection(eligible)
    )
  }
}
