import Foundation
import iCordisKernel

/// Records every tool call made in a run and answers repeats from cache.
///
/// This replaces the previous repetition guard, which *blocked* a repeated call
/// and reported the block through the parser-error channel — so the model was
/// told its output could not be parsed when in fact a policy had rejected it.
/// Blocking also left the model with no result at all, which is precisely the
/// state that makes it try again.
///
/// A receipt is the opposite move: the repeat is answered immediately with the
/// result it already produced, plus a note saying so. The model learns "this
/// path yields nothing new" from data rather than from an adversarial refusal,
/// and the run does not spend a second execution on it.
public struct AgentToolCallLedger: Sendable {
  public struct Receipt: Sendable {
    public var callIndex: Int
    public var observation: String
    public var isFailure: Bool

    public init(callIndex: Int, observation: String, isFailure: Bool) {
      self.callIndex = callIndex
      self.observation = observation
      self.isFailure = isFailure
    }
  }

  public enum Resolution: Sendable {
    /// Not seen before, or worth genuinely retrying — execute it.
    case execute
    /// Answer from the ledger without spending a tool call.
    case cached(observation: String, isFailure: Bool)
  }

  private var receipts: [String: Receipt] = [:]
  private var repeatCounts: [String: Int] = [:]
  private let maximumIdenticalFailureRetries: Int

  /// Tools whose result legitimately changes between identical calls. These
  /// are never answered from cache.
  private let volatileToolIDs: Set<String>

  public init(
    maximumIdenticalFailureRetries: Int = 1,
    volatileToolIDs: Set<String> = [
      AgentBuiltinToolID.runAppCommand,
      AgentBuiltinToolID.runCode,
      AgentBuiltinToolID.waitForAppUI,
      AgentBuiltinToolID.inspectAppUI,
      AgentBuiltinToolID.actOnAppUI,
    ]
  ) {
    self.maximumIdenticalFailureRetries = max(0, maximumIdenticalFailureRetries)
    self.volatileToolIDs = volatileToolIDs
  }

  public func resolve(_ toolCall: AgentToolCall) -> Resolution {
    if toolCall.arguments["refresh"] == .bool(true) { return .execute }
    guard !isVolatile(toolCall) else { return .execute }
    let key = Self.signature(for: toolCall)
    guard let receipt = receipts[key] else { return .execute }

    if receipt.isFailure {
      // A failure can be transient (a timeout, a race). Allow a bounded
      // number of genuine retries before falling back to the receipt.
      // `repeatCounts` counts attempts already made, so one recorded
      // failure still leaves the configured retry budget intact.
      guard repeatCounts[key, default: 0] > maximumIdenticalFailureRetries else {
        return .execute
      }
    }

    return .cached(
      observation: """
        [runtime] This request is byte-identical to tool call #\(receipt.callIndex) in this run, \
        so it was answered from that call's result instead of being executed again. \
        Repeating it cannot reveal anything new — change the arguments (a different range, \
        query, page, or format), choose another tool, or answer from what you already have.

        \(receipt.observation)
        """,
      isFailure: receipt.isFailure
    )
  }

  public mutating func record(
    _ toolCall: AgentToolCall,
    callIndex: Int,
    observation: String,
    isFailure: Bool
  ) {
    let key = Self.signature(for: toolCall)
    repeatCounts[key, default: 0] += 1
    // Keep the first successful result as the canonical receipt; a later
    // failure of the same request should not erase evidence already used.
    if let existing = receipts[key], existing.isFailure == false, isFailure {
      return
    }
    receipts[key] = Receipt(callIndex: callIndex, observation: observation, isFailure: isFailure)
  }

  /// Invalidates read receipts whose answer may have changed after a
  /// successful mutation. A signature-only cache cannot safely reuse
  /// `validate(packagePath:)` after that package was edited, or a Plugin list
  /// after lifecycle state changed.
  public mutating func invalidateAfterSuccessfulCall(_ toolCall: AgentToolCall) {
    if isWorkspaceMutation(toolCall) {
      removeReceipts(for: [
        AgentBuiltinToolID.fileSystem,
        AgentBuiltinToolID.readCodeFile,
        AgentBuiltinToolID.listCodeFiles,
        AgentBuiltinToolID.inspectCodeWorkspace,
        PluginToolIDs.validateCapabilityID,
        PluginToolIDs.testCapabilityID,
        PluginToolIDs.installCapabilityID,
      ])
    }

    if toolCall.capabilityID == PluginToolIDs.scaffoldCapabilityID {
      removeReceipts(for: [
        AgentBuiltinToolID.fileSystem,
        AgentBuiltinToolID.readCodeFile,
        AgentBuiltinToolID.listCodeFiles,
        PluginToolIDs.validateCapabilityID,
        PluginToolIDs.testCapabilityID,
      ])
    }

    if toolCall.capabilityID == PluginToolIDs.installCapabilityID
      || toolCall.capabilityID == PluginToolIDs.lifecycleCapabilityID
    {
      removeReceipts(for: [
        PluginToolIDs.listCapabilityID,
        AgentBuiltinToolID.searchTools,
      ])
    }
  }

  /// A failed contract check means the model needs a fresh read of the package
  /// it is about to repair. Caching those reads is what produced empty repair loops.
  public mutating func invalidateRepairReads(afterFailed toolCall: AgentToolCall) {
    guard
      toolCall.capabilityID == PluginToolIDs.validateCapabilityID
        || toolCall.capabilityID == PluginToolIDs.testCapabilityID
    else {
      return
    }
    removeReceipts(for: [
      AgentBuiltinToolID.fileSystem,
      AgentBuiltinToolID.readCodeFile,
      AgentBuiltinToolID.listCodeFiles,
      PluginToolIDs.standardCapabilityID,
    ])
  }

  private func isVolatile(_ toolCall: AgentToolCall) -> Bool {
    volatileToolIDs.contains(toolCall.capabilityID)
      || toolCall.capabilityID == PluginToolIDs.listCapabilityID
      || toolCall.capabilityID == PluginToolIDs.standardCapabilityID
      || toolCall.capabilityID == PluginToolIDs.validateCapabilityID
      || toolCall.capabilityID == PluginToolIDs.testCapabilityID
      || toolCall.capabilityID == PluginToolIDs.lifecycleCapabilityID
      || toolCall.capabilityID.hasPrefix("plugin.")
  }

  private func isWorkspaceMutation(_ toolCall: AgentToolCall) -> Bool {
    switch toolCall.capabilityID {
    case AgentBuiltinToolID.incrementalWriteCode, AgentBuiltinToolID.replaceCodeText,
      AgentBuiltinToolID.runAppCommand, AgentBuiltinToolID.runCode,
      PluginToolIDs.scaffoldCapabilityID:
      return true
    case AgentBuiltinToolID.fileSystem:
      let operation = toolCall.arguments["operation"]?.stringValue?.lowercased() ?? ""
      return !["read", "cat", "stat", "info", "metadata", "list", "ls"].contains(operation)
    default:
      return false
    }
  }

  private mutating func removeReceipts(for toolIDs: Set<String>) {
    receipts = receipts.filter { key, _ in
      guard let separator = key.firstIndex(of: "\n") else { return true }
      return !toolIDs.contains(String(key[..<separator]))
    }
    repeatCounts = repeatCounts.filter { key, _ in
      guard let separator = key.firstIndex(of: "\n") else { return true }
      return !toolIDs.contains(String(key[..<separator]))
    }
  }

  /// Arguments that do not change what a tool does, and so must not make an
  /// otherwise-identical repeat look new.
  ///
  /// A model that rewords a cosmetic field on each attempt would otherwise
  /// defeat the ledger entirely — observed in the wild as seven executions of
  /// `william.app.user_action` (and seventeen folder prompts to the user)
  /// because the model varied its `prompt` text every time.
  private static let cosmeticArgumentKeys: Set<String> = [
    "rationale", "reason", "prompt", "message", "note",
  ]

  /// Tools whose identity is only a subset of their arguments.
  private static let identityArgumentKeys: [String: Set<String>] = [
    AgentBuiltinToolID.requestLocalAppAction: ["action", "replaceExisting"]
  ]

  public static func signature(for toolCall: AgentToolCall) -> String {
    var arguments = toolCall.arguments
    if let identity = identityArgumentKeys[toolCall.capabilityID] {
      arguments = arguments.filter { identity.contains($0.key) }
    } else {
      arguments = arguments.filter { !cosmeticArgumentKeys.contains($0.key) }
    }
    // Runtime-injected bookkeeping is not part of what the model asked for.
    arguments = arguments.filter { !$0.key.hasPrefix("_") }

    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    let encodedArguments =
      (try? encoder.encode(arguments))
      .flatMap { String(data: $0, encoding: .utf8) } ?? "{}"
    return "\(toolCall.capabilityID)\n\(encodedArguments)"
  }
}
