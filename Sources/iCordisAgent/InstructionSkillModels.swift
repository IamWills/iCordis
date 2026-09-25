import Foundation
import iCordisKernel

public enum InstructionSkillTrust: String, Codable, Hashable, Sendable {
  case bundled
  case userInstalled
}

public enum AgentRunRequirement: String, Codable, CaseIterable, Hashable, Sendable {
  case workingDirectorySelected
  case codeSearchBeforeEdit
  case appRegistered
  case appOpenedInWilliam
}

public struct InstructionSkillManifest: Codable, Hashable, Sendable {
  public var id: String
  public var version: Int
  public var isEnabled: Bool
  /// Every group must match at least one term. This keeps activation deterministic.
  public var triggerGroups: [[String]]
  public var requirements: [AgentRunRequirement]
  public var references: [String]
  public var provenance: InstructionSkillProvenance? = nil

  public init(
    id: String, version: Int, isEnabled: Bool, triggerGroups: [[String]],
    requirements: [AgentRunRequirement], references: [String],
    provenance: InstructionSkillProvenance? = nil
  ) {
    self.id = id
    self.version = version
    self.isEnabled = isEnabled
    self.triggerGroups = triggerGroups
    self.requirements = requirements
    self.references = references
    self.provenance = provenance
  }
}

public struct InstructionSkillProvenance: Codable, Hashable, Sendable {
  public var generatedBy: String
  public var sourceRunID: UUID
  public var sourceSessionID: UUID
  public var reason: String
  public var evidenceSummary: String
  public var createdAt: Date

  public init(
    generatedBy: String, sourceRunID: UUID, sourceSessionID: UUID, reason: String,
    evidenceSummary: String, createdAt: Date
  ) {
    self.generatedBy = generatedBy
    self.sourceRunID = sourceRunID
    self.sourceSessionID = sourceSessionID
    self.reason = reason
    self.evidenceSummary = evidenceSummary
    self.createdAt = createdAt
  }
}

public enum InstructionSkillActivityAction: String, Codable, Hashable, Sendable {
  case drafted
  case published
  case updated
  case disabled
  case rejected
}

public struct InstructionSkillActivityRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var skillID: String
  public var version: Int?
  public var action: InstructionSkillActivityAction
  public var reason: String
  public var sourceRunID: UUID?
  public var sourceSessionID: UUID?
  public var createdAt: Date

  public init(
    id: UUID, skillID: String, version: Int? = nil, action: InstructionSkillActivityAction,
    reason: String, sourceRunID: UUID? = nil, sourceSessionID: UUID? = nil, createdAt: Date
  ) {
    self.id = id
    self.skillID = skillID
    self.version = version
    self.action = action
    self.reason = reason
    self.sourceRunID = sourceRunID
    self.sourceSessionID = sourceSessionID
    self.createdAt = createdAt
  }
}

public struct AutonomousInstructionSkillRequest: Hashable, Sendable {
  public var id: String
  public var name: String
  public var description: String
  public var instructions: String
  public var triggerGroups: [[String]]
  public var references: [String: String]
  public var reason: String
  public var evidenceSummary: String
  public var expectedVersion: Int?
  public var sourceRunID: UUID
  public var sourceSessionID: UUID

  public init(
    id: String, name: String, description: String, instructions: String, triggerGroups: [[String]],
    references: [String: String], reason: String, evidenceSummary: String,
    expectedVersion: Int? = nil, sourceRunID: UUID, sourceSessionID: UUID
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.instructions = instructions
    self.triggerGroups = triggerGroups
    self.references = references
    self.reason = reason
    self.evidenceSummary = evidenceSummary
    self.expectedVersion = expectedVersion
    self.sourceRunID = sourceRunID
    self.sourceSessionID = sourceSessionID
  }
}

public struct AutonomousInstructionSkillMutationResult: Hashable, Sendable {
  public var descriptor: InstructionSkillDescriptor
  public var mode: AutonomousSkillLearningMode
  public var location: URL
  public var activity: InstructionSkillActivityRecord

  public init(
    descriptor: InstructionSkillDescriptor, mode: AutonomousSkillLearningMode, location: URL,
    activity: InstructionSkillActivityRecord
  ) {
    self.descriptor = descriptor
    self.mode = mode
    self.location = location
    self.activity = activity
  }
}

public struct AutonomousInstructionSkillSearchResult: Hashable, Sendable {
  public var descriptors: [InstructionSkillDescriptor]
  public var activities: [InstructionSkillActivityRecord]

  public init(
    descriptors: [InstructionSkillDescriptor], activities: [InstructionSkillActivityRecord]
  ) {
    self.descriptors = descriptors
    self.activities = activities
  }
}

public struct InstructionSkillDescriptor: Hashable, Identifiable, Sendable {
  public var id: String
  public var name: String
  public var description: String
  public var version: Int
  public var trust: InstructionSkillTrust

  public init(
    id: String, name: String, description: String, version: Int, trust: InstructionSkillTrust
  ) {
    self.id = id
    self.name = name
    self.description = description
    self.version = version
    self.trust = trust
  }
}

public struct ActivatedInstructionSkill: Hashable, Sendable {
  public var descriptor: InstructionSkillDescriptor
  public var instructions: String
  public var requirements: Set<AgentRunRequirement>
  public var references: [String]

  public init(
    descriptor: InstructionSkillDescriptor, instructions: String,
    requirements: Set<AgentRunRequirement>, references: [String]
  ) {
    self.descriptor = descriptor
    self.instructions = instructions
    self.requirements = requirements
    self.references = references
  }
}

public struct InstructionSkillContext: Hashable, Sendable {
  public var availableSkillMetadata: String
  public var trustedSystemInstructions: String
  public var userGuidance: String
  public var activeSkillIDs: Set<String>
  public var requirements: Set<AgentRunRequirement>

  public static let empty = InstructionSkillContext(
    availableSkillMetadata: "",
    trustedSystemInstructions: "",
    userGuidance: "",
    activeSkillIDs: [],
    requirements: []
  )

  public init(
    availableSkillMetadata: String, trustedSystemInstructions: String, userGuidance: String,
    activeSkillIDs: Set<String>, requirements: Set<AgentRunRequirement>
  ) {
    self.availableSkillMetadata = availableSkillMetadata
    self.trustedSystemInstructions = trustedSystemInstructions
    self.userGuidance = userGuidance
    self.activeSkillIDs = activeSkillIDs
    self.requirements = requirements
  }
}

public struct InstructionSkillReference: Hashable, Sendable {
  public var skillID: String
  public var path: String
  public var content: String
  public var trust: InstructionSkillTrust

  public init(skillID: String, path: String, content: String, trust: InstructionSkillTrust) {
    self.skillID = skillID
    self.path = path
    self.content = content
    self.trust = trust
  }
}

public enum AgentRunCompletionStatus: String, Codable, Hashable, Sendable {
  case completed
  case incomplete
  case blocked
  case cancelled
}

public struct AgentPluginPackageEvidence: Hashable, Sendable {
  public var pluginID: String
  public var packagePath: String
  public var ordinal: Int

  public init(pluginID: String, packagePath: String, ordinal: Int) {
    self.pluginID = pluginID
    self.packagePath = packagePath
    self.ordinal = ordinal
  }
}

public struct AgentPluginCapabilityEvidence: Hashable, Sendable {
  public var capabilityID: String
  public var ordinal: Int

  public init(capabilityID: String, ordinal: Int) {
    self.capabilityID = capabilityID
    self.ordinal = ordinal
  }
}

public struct AgentPluginLifecycleEvidence: Hashable, Sendable {
  public var pluginID: String
  public var ordinal: Int

  public init(pluginID: String, ordinal: Int) {
    self.pluginID = pluginID
    self.ordinal = ordinal
  }
}

public struct AgentRunEvidence: Hashable, Sendable {
  public private(set) var successfulCodeSearches = 0
  public private(set) var successfulCodeMutations = 0
  /// Mutations that changed content already on disk, as opposed to creating a
  /// file. "Search before you edit" only has meaning for the former.
  public private(set) var successfulExistingContentEdits = 0
  public private(set) var registeredAppIDs: [UUID: Int] = [:]
  public private(set) var openedAppIDs: [UUID: Int] = [:]
  private var ordinal = 0
  public private(set) var successfulLearningEvidenceCalls = 0
  public private(set) var successfulAutonomousSkillMutations = 0
  public private(set) var searchedInstructionSkills = false
  public private(set) var lastCodeMutationOrdinal: Int?
  public private(set) var firstCodeMutationOrdinal: Int?
  public private(set) var pluginStandardOrdinals: [Int] = []
  public private(set) var pluginScaffoldOrdinals: [Int] = []
  public private(set) var pluginValidations: [AgentPluginPackageEvidence] = []
  public private(set) var pluginContractTests: [AgentPluginPackageEvidence] = []
  public private(set) var pluginInstalls: [AgentPluginLifecycleEvidence] = []
  public private(set) var pluginStarts: [AgentPluginLifecycleEvidence] = []
  public private(set) var pluginInvocations: [AgentPluginCapabilityEvidence] = []
  public private(set) var restoredThroughOrdinal = 0

  public var hasSuccessfulCodeSearch: Bool {
    successfulCodeSearches > 0
  }

  public var canAutonomouslyWriteSkill: Bool {
    searchedInstructionSkills && successfulLearningEvidenceCalls >= 2
      && successfulAutonomousSkillMutations == 0
  }

  public static func isAutonomousSkillMutation(_ toolCall: AgentToolCall) -> Bool {
    [
      AgentBuiltinToolID.createInstructionSkill,
      AgentBuiltinToolID.updateInstructionSkill,
      AgentBuiltinToolID.disableInstructionSkill,
    ].contains(toolCall.capabilityID)
  }

  private static func isLearningEvidence(_ toolCall: AgentToolCall) -> Bool {
    let excluded = [
      AgentBuiltinToolID.searchTools,
      AgentBuiltinToolID.searchInstructionSkills,
      AgentBuiltinToolID.validateInstructionSkill,
      AgentBuiltinToolID.loadInstructionReference,
      AgentBuiltinToolID.inspectSettings,
      AgentBuiltinToolID.inspectSession,
      AgentBuiltinToolID.searchMemory,
      AgentBuiltinToolID.listMemories,
      AgentBuiltinToolID.createSkill,
      AgentBuiltinToolID.remember,
      AgentBuiltinToolID.updateMemory,
      AgentBuiltinToolID.forgetMemory,
      AgentBuiltinToolID.listSessions,
      AgentBuiltinToolID.searchConversation,
      AgentBuiltinToolID.listModels,
      AgentBuiltinToolID.inspectRuntime,
      AgentBuiltinToolID.listApps,
      AgentBuiltinToolID.listCodeWorkspaces,
      AgentBuiltinToolID.listCodeFiles,
      AgentBuiltinToolID.requestLocalAppAction,
    ]
    return !excluded.contains(toolCall.capabilityID) && !isAutonomousSkillMutation(toolCall)
  }

  /// True when the call changes content that already exists rather than
  /// creating something new. A greenfield App has nothing to search for, so
  /// requiring a prior search before its first write is a dead end.
  public static func isEditOfExistingContent(_ toolCall: AgentToolCall) -> Bool {
    switch toolCall.capabilityID {
    case AgentBuiltinToolID.replaceCodeText:
      return true
    case AgentBuiltinToolID.incrementalWriteCode:
      if toolCall.arguments["truncate"] == .bool(true) { return false }
      if let offset = toolCall.arguments["expectedOffset"], offset == .number(0) { return false }
      return toolCall.arguments["expectedOffset"] != nil
    case AgentBuiltinToolID.fileSystem:
      let operation = toolCall.arguments["operation"]?.stringValue?.lowercased() ?? ""
      return ["edit", "append", "move", "copy", "delete"].contains(operation)
    default:
      return false
    }
  }

  public static func isCodeMutation(_ toolCall: AgentToolCall) -> Bool {
    switch toolCall.capabilityID {
    case AgentBuiltinToolID.incrementalWriteCode, AgentBuiltinToolID.replaceCodeText:
      return true
    case AgentBuiltinToolID.fileSystem:
      let operation = toolCall.arguments["operation"]?.stringValue?.lowercased()
      return ["write", "append", "edit", "move", "copy", "delete"].contains(operation)
    default:
      return false
    }
  }

  public mutating func record(toolCall: AgentToolCall, trace: CapabilityExecutionTrace) {
    ordinal += 1
    if Self.isLearningEvidence(toolCall) {
      successfulLearningEvidenceCalls += 1
    }
    if toolCall.capabilityID == AgentBuiltinToolID.searchInstructionSkills {
      searchedInstructionSkills = true
    }
    if Self.isAutonomousSkillMutation(toolCall) {
      successfulAutonomousSkillMutations += 1
    }
    switch toolCall.capabilityID {
    case AgentBuiltinToolID.searchCode:
      successfulCodeSearches += 1
    case AgentBuiltinToolID.incrementalWriteCode, AgentBuiltinToolID.replaceCodeText:
      successfulCodeMutations += 1
      firstCodeMutationOrdinal = firstCodeMutationOrdinal ?? ordinal
      lastCodeMutationOrdinal = ordinal
      if Self.isEditOfExistingContent(toolCall) { successfulExistingContentEdits += 1 }
    case AgentBuiltinToolID.fileSystem:
      if Self.isCodeMutation(toolCall) {
        successfulCodeMutations += 1
        firstCodeMutationOrdinal = firstCodeMutationOrdinal ?? ordinal
        lastCodeMutationOrdinal = ordinal
        if Self.isEditOfExistingContent(toolCall) { successfulExistingContentEdits += 1 }
      }
    case AgentBuiltinToolID.registerApp:
      if let id = trace.result.rawPayload?["id"]?.stringValue.flatMap(UUID.init(uuidString:)) {
        registeredAppIDs[id] = ordinal
      }
    case AgentBuiltinToolID.openApp:
      if let id = trace.result.rawPayload?["appID"]?.stringValue.flatMap(UUID.init(uuidString:)) {
        openedAppIDs[id] = ordinal
      }
    case PluginToolIDs.standardCapabilityID:
      pluginStandardOrdinals.append(ordinal)
    case PluginToolIDs.scaffoldCapabilityID:
      successfulCodeMutations += 1
      firstCodeMutationOrdinal = firstCodeMutationOrdinal ?? ordinal
      lastCodeMutationOrdinal = ordinal
      pluginScaffoldOrdinals.append(ordinal)
    case PluginToolIDs.validateCapabilityID:
      if trace.result.rawPayload?["isValid"] == .bool(true),
        let path = toolCall.arguments["packagePath"]?.stringValue
      {
        pluginValidations.append(
          AgentPluginPackageEvidence(
            pluginID: trace.result.rawPayload?["pluginID"]?.stringValue ?? "",
            packagePath: URL(fileURLWithPath: path).standardizedFileURL.path,
            ordinal: ordinal
          ))
      }
    case PluginToolIDs.testCapabilityID:
      if trace.result.rawPayload?["passed"] == .bool(true),
        let pluginID = trace.result.rawPayload?["pluginID"]?.stringValue,
        let path = trace.result.rawPayload?["packagePath"]?.stringValue
      {
        pluginContractTests.append(
          AgentPluginPackageEvidence(
            pluginID: pluginID,
            packagePath: URL(fileURLWithPath: path).standardizedFileURL.path,
            ordinal: ordinal
          ))
      }
    case PluginToolIDs.installCapabilityID:
      if let pluginID = trace.result.rawPayload?["id"]?.stringValue {
        pluginInstalls.append(AgentPluginLifecycleEvidence(pluginID: pluginID, ordinal: ordinal))
      }
    case PluginToolIDs.lifecycleCapabilityID:
      if toolCall.arguments["action"]?.stringValue == "start",
        trace.result.rawPayload?["state"]?.stringValue == "running",
        let pluginID = trace.result.rawPayload?["id"]?.stringValue
      {
        pluginStarts.append(AgentPluginLifecycleEvidence(pluginID: pluginID, ordinal: ordinal))
      }
    default:
      if toolCall.capabilityID.hasPrefix("plugin.") {
        pluginInvocations.append(
          AgentPluginCapabilityEvidence(
            capabilityID: toolCall.capabilityID,
            ordinal: ordinal
          ))
      }
      break
    }
  }

  /// Rehydrates successful capability traces belonging to one explicitly
  /// selected Agent run. Trace order is not assumed; the run's timestamps are
  /// the durable boundary because persisted timelines may be newest-first.
  public static func restoringRun(id runID: UUID, from session: ConversationSession)
    -> AgentRunEvidence
  {
    var evidence = AgentRunEvidence()
    guard
      let run = session.traces.first(where: {
        $0.request.capabilityID == "agent.run" && $0.id == runID
      })
    else { return evidence }
    let traces = session.traces
      .filter {
        $0.request.capabilityID != "agent.run"
          && $0.result.success
          && $0.startedAt >= run.startedAt
          && $0.finishedAt <= run.finishedAt
      }
      .sorted { $0.startedAt < $1.startedAt }
    for trace in traces {
      evidence.record(
        toolCall: AgentToolCall(
          capabilityID: trace.request.capabilityID,
          arguments: trace.request.arguments,
          rationale: nil
        ),
        trace: trace
      )
    }
    evidence.restoredThroughOrdinal = evidence.ordinal
    return evidence
  }

  public func pluginDevelopmentUnmetRequirements() -> [String] {
    var unmet: [String] = []
    let firstMutation = firstCodeMutationOrdinal ?? Int.max
    let readGuidanceBeforeAuthoring = pluginStandardOrdinals.contains(where: { $0 < firstMutation })
    let usedHostScaffold = pluginScaffoldOrdinals.contains(where: { $0 <= firstMutation })
    guard readGuidanceBeforeAuthoring || usedHostScaffold else {
      return [
        "The WPS guidance was not read. Call william.plugins.standard or william.plugins.scaffold before developing the Plugin."
      ]
    }
    let mutationOrdinal = lastCodeMutationOrdinal ?? 0
    guard let validation = pluginValidations.last(where: { $0.ordinal > mutationOrdinal }) else {
      return [
        "The final Plugin package contents were not statically validated after the last file change. Call william.plugins.validate again."
      ]
    }
    guard
      let contractTest = pluginContractTests.last(where: {
        $0.packagePath == validation.packagePath && $0.ordinal > validation.ordinal
      })
    else {
      return [
        "The validated Plugin package did not pass william.plugins.test after validation. Include a representative toolID and arguments."
      ]
    }
    let pluginID = contractTest.pluginID
    let installation = pluginInstalls.last(where: {
      $0.pluginID == pluginID && $0.ordinal > contractTest.ordinal
    })
    let impliedInstall =
      pluginInstalls.contains { $0.pluginID == pluginID }
      || pluginStarts.contains { $0.pluginID == pluginID && $0.ordinal > contractTest.ordinal }
      || pluginInvocations.contains {
        $0.ordinal > contractTest.ordinal && $0.capabilityID.hasPrefix("plugin.\(pluginID).")
      }
    guard installation != nil || impliedInstall else {
      return ["The contract-tested Plugin was not installed after its successful preflight test."]
    }
    guard
      let start = pluginStarts.last(where: {
        $0.pluginID == pluginID
          && $0.ordinal > restoredThroughOrdinal
          && $0.ordinal > (installation?.ordinal ?? contractTest.ordinal)
      })
    else {
      return [
        "The installed Plugin does not have a fresh successful start observation in this continuation run."
      ]
    }
    let invoked = pluginInvocations.contains {
      $0.ordinal > start.ordinal && $0.capabilityID.hasPrefix("plugin.\(start.pluginID).")
    }
    if !invoked {
      unmet.append(
        "No exported plugin.\(start.pluginID).* Tool was invoked successfully after startup. Search for it, call it with representative input, and verify the result."
      )
    }
    return unmet
  }

  public func wasOpenedAfterRegistration(_ appID: UUID) -> Bool {
    guard let registered = registeredAppIDs[appID], let opened = openedAppIDs[appID] else {
      return false
    }
    return opened > registered
  }

  public init() {}
}

public struct AgentCompletionGateResult: Hashable, Sendable {
  public var isSatisfied: Bool
  public var unmetRequirements: [String]

  public static let satisfied = AgentCompletionGateResult(isSatisfied: true, unmetRequirements: [])

  public init(isSatisfied: Bool, unmetRequirements: [String]) {
    self.isSatisfied = isSatisfied
    self.unmetRequirements = unmetRequirements
  }
}

extension JSONValue {
  fileprivate subscript(key: String) -> JSONValue? {
    guard case .object(let object) = self else { return nil }
    return object[key]
  }
}
