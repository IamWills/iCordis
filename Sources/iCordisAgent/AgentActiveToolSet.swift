import Foundation
import iCordisKernel

/// The set of tools declared to the model right now, and how it grows.
///
/// A run starts with `william.tools.search` plus any deliberately small
/// pre-activated control-plane groups. Search results are then declared with
/// their complete schemas on the next model turn. Open-ended groups, including
/// tools exported by installed Plugins, are never pre-declared.
///
/// The declared set is capped. Without a ceiling, on-demand loading only delays
/// the problem — a long run keeps revealing tools until it is again declaring
/// hundreds. Eviction prefers tools that were revealed but never actually
/// called, and never touches an activated group, so the model does not lose
/// something it is part-way through using.
public struct AgentActiveToolSet: Sendable {
  /// Roughly where tool choice starts degrading for current models, and
  /// comfortably under any provider's declaration limit.
  public static let defaultMaxDeclaredTools = 48

  private let catalog: AgentToolCatalog
  private let groups: AgentToolGroupCatalog
  private var availability: AgentToolAvailability
  private let maxDeclaredTools: Int
  private let maxAdvertisedGroups: Int

  private var activeGroups: Set<AgentToolGroupID>
  /// Revealed individually, in reveal order — this doubles as the eviction queue.
  private var revealedToolIDs: [String] = []
  /// Matches that become callable after session state changes, such as code
  /// tools discovered before the user chooses a working directory.
  private var pendingToolIDs: [String] = []
  private var usedToolIDs: Set<String> = []
  public private(set) var evictedToolIDs: Set<String> = []

  public init(
    catalog: AgentToolCatalog,
    availability: AgentToolAvailability,
    maxDeclaredTools: Int = AgentActiveToolSet.defaultMaxDeclaredTools,
    maxAdvertisedGroups: Int = 12
  ) {
    let groupCatalog = AgentToolGroupCatalog(descriptors: catalog.allDescriptors)
    self.catalog = catalog
    self.groups = groupCatalog
    self.availability = availability
    self.maxDeclaredTools = max(8, maxDeclaredTools)
    self.maxAdvertisedGroups = max(4, maxAdvertisedGroups)
    // Keep the resident surface bounded and explicit. In particular, a
    // workspace must not silently add every code schema before the model
    // has asked for code capabilities.
    self.activeGroups = availability.preActivated.filter {
      availability.isEligible($0) && groupCatalog.toolCount(in: $0) > 0
    }
  }

  // MARK: - Declaration

  public var declaredDescriptors: [CapabilityDescriptor] {
    let advertised = advertisableGroups
    let revealed = Set(revealedToolIDs)
    return catalog.allDescriptors.compactMap { descriptor in
      if descriptor.id == AgentBuiltinToolID.searchTools {
        return descriptor
      }
      if descriptor.id == AgentBuiltinToolID.activateToolGroup {
        guard revealed.contains(descriptor.id) || isActive(descriptor.id) else { return nil }
        guard !advertised.isEmpty || !blockedGroups.isEmpty else { return nil }
        var activation = descriptor
        activation.summary = activationSummary(advertised)
        return activation
      }
      if descriptor.id == AgentBuiltinToolID.runCode, isActive(descriptor.id) {
        var sandbox = descriptor
        let index = scriptableToolIndex
        sandbox.summary = index.isEmpty ? descriptor.summary : descriptor.summary + "\n\n" + index
        return sandbox
      }
      return isActive(descriptor.id) || revealed.contains(descriptor.id) ? descriptor : nil
    }
  }

  public var declaredToolCount: Int { declaredDescriptors.count }

  public func isDeclared(_ capabilityID: String) -> Bool {
    capabilityID == AgentBuiltinToolID.searchTools
      || isActive(capabilityID)
      || revealedToolIDs.contains(capabilityID)
  }

  private func isActive(_ capabilityID: String) -> Bool {
    guard let group = groups.group(forToolID: capabilityID) else { return false }
    return activeGroups.contains(group)
  }

  /// Marks a tool as genuinely used, so eviction leaves it alone.
  public mutating func noteUsed(_ capabilityID: String) {
    usedToolIDs.insert(capabilityID)
  }

  /// Widens eligibility mid-run without losing what is already open.
  ///
  /// Session state is not fixed for the length of a run: the user can pick a
  /// working directory through `william.app.user_action`, which is exactly
  /// what unlocks the code and app groups. Computing eligibility once at run
  /// start left those groups permanently invisible, so a run that began
  /// without a directory could never build an App no matter what the user
  /// chose. Newly eligible groups are *not* auto-activated — the model opens
  /// them, so the change stays visible in the trajectory.
  @discardableResult
  public
    mutating func updateAvailability(_ updated: AgentToolAvailability) -> [String]
  {
    availability = AgentToolAvailability(
      eligible: availability.eligible.union(updated.eligible),
      preActivated: availability.preActivated,
      allowsExternalGroups: availability.allowsExternalGroups || updated.allowsExternalGroups
    )
    let pending = pendingToolIDs
    pendingToolIDs.removeAll(keepingCapacity: true)
    return reveal(toolIDs: pending)
  }

  // MARK: - Group menu

  public var activeGroupNames: [String] {
    activeGroups.map(\.rawValue).sorted()
  }

  public var activatableGroups: [(group: AgentToolGroupID, toolCount: Int)] {
    groups.allGroups
      .filter { !activeGroups.contains($0) && availability.isEligible($0) }
      .map { ($0, groups.toolCount(in: $0)) }
      .filter { $0.1 > 0 }
  }

  /// Groups that exist but cannot be opened yet, with what would unblock them.
  ///
  /// These are listed alongside the activatable ones. A hidden capability is
  /// worse than a blocked one: the model cannot tell the difference between
  /// "William cannot do this" and "not yet", so it improvises — which is how a
  /// run with no working directory spent 32 iterations re-asking for one
  /// instead of registering an App.
  public var blockedGroups: [(group: AgentToolGroupID, toolCount: Int, reason: String)] {
    groups.allGroups
      .filter { !activeGroups.contains($0) && !availability.isEligible($0) && $0.isBuiltin }
      .map { ($0, groups.toolCount(in: $0), Self.ineligibilityReason(for: $0)) }
      .filter { $0.1 > 0 }
      .sorted { $0.0 < $1.0 }
  }

  /// What the activation tool actually lists. Capped, because with many
  /// connected servers the menu itself becomes the context problem the menu
  /// was supposed to solve.
  private var advertisableGroups: [(group: AgentToolGroupID, toolCount: Int)] {
    let sorted = activatableGroups.sorted { lhs, rhs in
      // Builtin groups first — a stable, well-known taxonomy — then the
      // largest external ones. Search covers whatever does not fit.
      if lhs.group.isBuiltin != rhs.group.isBuiltin { return lhs.group.isBuiltin }
      if lhs.toolCount != rhs.toolCount { return lhs.toolCount > rhs.toolCount }
      return lhs.group < rhs.group
    }
    return Array(sorted.prefix(maxAdvertisedGroups))
  }

  private func activationSummary(_ advertised: [(group: AgentToolGroupID, toolCount: Int)])
    -> String
  {
    let hidden = activatableGroups.count - advertised.count
    let overflow =
      hidden > 0
      ? "\n…and \(hidden) more group(s). Use \(AgentBuiltinToolID.searchTools) to reach tools in those."
      : ""
    let blocked = blockedGroups
    let blockedSection =
      blocked.isEmpty
      ? ""
      : """

      Not available yet — do the stated step first, then activate:
      \(blocked.map { "- \($0.group.rawValue) (\($0.toolCount) tools): \($0.reason)" }
            .joined(separator: "\n"))
      """
    return """
      Make a group of related tools available for the rest of this run. Call this before attempting \
      work that needs them; do not guess at tool names. Groups not yet activated:
      \(advertised.map { "- \($0.group.rawValue) (\($0.toolCount) tools): \(groups.summary(for: $0.group))" }
            .joined(separator: "\n"))\(overflow)\(blockedSection)
      """
  }

  // MARK: - Widening

  public enum ActivationOutcome: Sendable, Equatable {
    case activated(group: AgentToolGroupID, toolIDs: [String])
    case alreadyActive(group: AgentToolGroupID)
    case notEligible(group: AgentToolGroupID, reason: String)
    case unknownGroup(name: String)
  }

  public mutating func activate(groupNamed name: String) -> ActivationOutcome {
    let group = AgentToolGroupID(name.trimmingCharacters(in: .whitespacesAndNewlines))
    guard groups.toolCount(in: group) > 0 else {
      return .unknownGroup(name: name)
    }
    guard availability.isEligible(group) else {
      return .notEligible(group: group, reason: Self.ineligibilityReason(for: group))
    }
    guard !activeGroups.contains(group) else {
      return .alreadyActive(group: group)
    }
    activeGroups.insert(group)
    enforceCeiling()
    return .activated(group: group, toolIDs: groups.toolIDs(in: group))
  }

  /// Tool search makes individual matches callable without opening their whole
  /// group. Search never *gates* a call — it only widens what is declared.
  @discardableResult
  public
    mutating func reveal(toolIDs: [String]) -> [String]
  {
    var newlyRevealed: [String] = []
    for id in toolIDs {
      guard id != AgentBuiltinToolID.searchTools else { continue }
      guard catalog.descriptor(for: id) != nil,
        let group = groups.group(forToolID: id)
      else {
        continue
      }
      guard availability.isEligible(group) else {
        if !pendingToolIDs.contains(id) { pendingToolIDs.append(id) }
        continue
      }
      guard
        !activeGroups.contains(group),
        !revealedToolIDs.contains(id)
      else {
        continue
      }
      pendingToolIDs.removeAll { $0 == id }
      revealedToolIDs.append(id)
      evictedToolIDs.remove(id)
      newlyRevealed.append(id)
    }
    enforceCeiling()
    return newlyRevealed.filter { revealedToolIDs.contains($0) }
  }

  /// A tool the model named that is not currently declared. Revealing and
  /// running it beats refusing: a refusal only sends the model back to
  /// discovery, which is the loop this design exists to remove.
  public mutating func revealIfKnown(_ capabilityID: String) -> Bool {
    if capabilityID == AgentBuiltinToolID.searchTools { return true }
    guard catalog.descriptor(for: capabilityID) != nil,
      let group = groups.group(forToolID: capabilityID),
      availability.isEligible(group)
    else {
      return false
    }
    if activeGroups.contains(group) || revealedToolIDs.contains(capabilityID) { return true }
    revealedToolIDs.append(capabilityID)
    evictedToolIDs.remove(capabilityID)
    enforceCeiling()
    return true
  }

  /// Explains why a catalog match could not become a declaration. Search is
  /// allowed to inspect the full catalog, so silently dropping an ineligible
  /// match creates a false promise: the model sees the tool in the result but
  /// cannot call it on the next turn.
  public func blockingReason(forToolID capabilityID: String) -> String? {
    guard let group = groups.group(forToolID: capabilityID),
      availability.isEligible(group) == false
    else {
      return nil
    }
    return Self.ineligibilityReason(for: group)
  }

  /// When discovery finds a capability with a deterministic prerequisite,
  /// declare the tool that performs that prerequisite on the next turn. This
  /// lets a search for “edit code” lead directly to the folder picker instead
  /// of forcing the model to invent a second search query.
  @discardableResult
  public
    mutating func revealPrerequisites(forBlockedToolIDs toolIDs: [String]) -> [String]
  {
    let blockedGroups = Set(
      toolIDs.compactMap { id -> AgentToolGroupID? in
        guard let group = groups.group(forToolID: id), !availability.isEligible(group) else {
          return nil
        }
        return group
      })
    var prerequisiteIDs: [String] = []
    if !blockedGroups.intersection([.code, .apps]).isEmpty {
      prerequisiteIDs.append(AgentBuiltinToolID.requestLocalAppAction)
    }
    if blockedGroups.contains(.appUI) {
      if availability.isEligible(.apps) {
        prerequisiteIDs.append(AgentBuiltinToolID.registerApp)
      } else {
        prerequisiteIDs.append(AgentBuiltinToolID.requestLocalAppAction)
      }
    }
    // Already-resident control-plane tools still count: search must name
    // the prerequisite even when it did not need a new declaration.
    _ = reveal(toolIDs: prerequisiteIDs)
    return prerequisiteIDs.filter { isDeclared($0) }
  }

  /// Drops individually revealed tools that were never called, oldest first,
  /// until the declaration fits. Activated groups are never trimmed: the model
  /// asked for those explicitly and is presumably mid-task with them.
  private mutating func enforceCeiling() {
    // The ceiling includes the one non-evictable resident search tool.
    var declared = 1 + activeToolCount + revealedToolIDs.count
    guard declared > maxDeclaredTools else { return }

    var index = 0
    while declared > maxDeclaredTools, index < revealedToolIDs.count {
      let candidate = revealedToolIDs[index]
      if usedToolIDs.contains(candidate) {
        index += 1
        continue
      }
      revealedToolIDs.remove(at: index)
      evictedToolIDs.insert(candidate)
      declared -= 1
    }
  }

  private var activeToolCount: Int {
    activeGroups.reduce(0) { $0 + groups.toolCount(in: $1) }
  }

  // MARK: - Scriptable surface

  /// A one-line-per-tool index of what the sandbox bridge can call.
  ///
  /// Capped for the same reason the group menu is: enumerating a few hundred
  /// tools here would reintroduce exactly the context cost that declaring them
  /// all would have had.
  private var scriptableToolIndex: String {
    let eligible = catalog.allDescriptors.filter { descriptor in
      !AgentToolBridgeService.forbiddenTools.contains(descriptor.id)
        && groups.group(forToolID: descriptor.id).map { availability.isEligible($0) } == true
    }
    guard !eligible.isEmpty else { return "" }

    let listed = eligible.sorted { $0.id < $1.id }.prefix(60)
    let hidden = eligible.count - listed.count
    let overflow =
      hidden > 0
      ? "\n…and \(hidden) more; use \(AgentBuiltinToolID.searchTools) to find them by description."
      : ""
    let lines = listed.map { descriptor -> String in
      let args = descriptor.schema.properties.keys.sorted()
        .filter { !$0.hasPrefix("_") }
        .joined(separator: ", ")
      return "- \(descriptor.id)(\(args)): \(Self.firstSentence(descriptor.summary))"
    }
    return """
      Inside the script, `william.call(toolID, argsObject)` invokes any tool below and returns its \
      JSON result (JavaScript: `await william.call(...)`; Python: `william.call(...)`). Use it to \
      chain several tools in one run instead of one model turn per call. Each bridged call counts \
      against the run's tool budget.
      \(lines.joined(separator: "\n"))\(overflow)
      """
  }

  private static func firstSentence(_ text: String) -> String {
    guard let end = text.firstIndex(where: { $0 == "." || $0 == "。" }) else {
      return String(text.prefix(120))
    }
    return String(text[..<end])
  }

  private static func ineligibilityReason(for group: AgentToolGroupID) -> String {
    switch group {
    case .code, .apps:
      return
        "No working directory is selected for this session. Use william.app.user_action with choose_working_directory first."
    case .appUI:
      return "No App is registered for this session yet. Register and open one first."
    case .skills:
      return "Skills are turned off in Settings."
    case .memory:
      return "Long-term memory is turned off in Settings."
    default:
      return "This group is not available in the current session."
    }
  }
}
