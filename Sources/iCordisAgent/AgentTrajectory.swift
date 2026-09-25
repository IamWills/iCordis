import Foundation
import iCordisKernel

/// The ordered, causal record of one Agent run.
///
/// This replaces the previous character-budgeted scratchpad, which flattened
/// every past turn into one text blob attached to a single user message. That
/// shape had two structural failure modes: the model never saw its own prior
/// turns as assistant messages, and — because the budget dropped "model action"
/// entries before observations — it routinely lost the record of *which tools it
/// had already called* while keeping their results. A model that can see an
/// observation but not the request that produced it will reissue the request.
///
/// The trajectory inverts both properties. Tool calls are structural entries
/// that are never dropped, and rendering produces real assistant/tool messages,
/// so the prompt prefix is stable enough to cache and the model has an actual
/// memory of what it did rather than a summary of what it saw.
public struct AgentTrajectory: Sendable {
  public enum RenderingMode: Sendable {
    /// Native `function_call` / `function_call_output` protocol items.
    case nativeToolCalls
    /// Assistant prose containing a JSON action, with results replayed as
    /// user messages. Used for local models without tool-calling support.
    case textProtocol
  }

  public struct ToolInvocation: Sendable {
    public var callID: String
    public var call: AgentToolCall
    public var observation: String
    public var isFailure: Bool
    /// Images or video returned by the tool. Carried separately because a
    /// `function_call_output` payload is a plain string.
    public var media: [ContentPart]
    /// Set when prompt-facing arguments have been semantically compressed.
    public var isElided: Bool = false
    /// The executed call stays immutable for receipts and audit. Only this
    /// prompt-facing copy may be compressed when large source bodies would
    /// otherwise escape the trajectory budget.
    public var renderedArguments: [String: JSONValue]? = nil

    public init(
      callID: String, call: AgentToolCall, observation: String, isFailure: Bool,
      media: [ContentPart], isElided: Bool = false, renderedArguments: [String: JSONValue]? = nil
    ) {
      self.callID = callID
      self.call = call
      self.observation = observation
      self.isFailure = isFailure
      self.media = media
      self.isElided = isElided
      self.renderedArguments = renderedArguments
    }
  }

  public enum Entry: Sendable {
    /// User-visible prose the model produced before its tool call, or its
    /// final answer.
    case assistantText(String)
    case toolInvocation(ToolInvocation)
    /// A runtime fact injected into the conversation — for example a budget
    /// notice. Rendered as a user turn so the model
    /// treats it as new input rather than as its own prior reasoning.
    case runtimeNote(String)
  }

  public private(set) var entries: [Entry] = []
  private let maxCharacters: Int
  private let elisionFloor: Int
  /// Whether the model can receive images at all. A text-only model does not
  /// merely ignore an attached screenshot — the provider rejects the whole
  /// request, which kills the run mid-task.
  private let acceptsImageInput: Bool

  /// - Parameters:
  ///   - maxCharacters: soft budget for the rendered trajectory body.
  ///   - elisionFloor: how much of an elided observation to keep as a stub, so
  ///     a compacted result still says what it was about.
  public init(maxCharacters: Int, elisionFloor: Int = 240, acceptsImageInput: Bool = true) {
    self.maxCharacters = max(2_000, maxCharacters)
    self.elisionFloor = max(80, elisionFloor)
    self.acceptsImageInput = acceptsImageInput
  }

  public var toolInvocations: [ToolInvocation] {
    entries.compactMap { entry in
      guard case .toolInvocation(let invocation) = entry else { return nil }
      return invocation
    }
  }

  public var hasAnyToolInvocation: Bool {
    entries.contains { if case .toolInvocation = $0 { return true } else { return false } }
  }

  public mutating func appendAssistantText(_ text: String) {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    entries.append(.assistantText(trimmed))
  }

  public mutating func appendToolInvocation(_ invocation: ToolInvocation) {
    entries.append(.toolInvocation(invocation))
  }

  public mutating func appendRuntimeNote(_ note: String) {
    let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    entries.append(.runtimeNote(trimmed))
  }

  // MARK: - Rendering

  public func promptMessages(mode: RenderingMode) -> [ConversationItem] {
    var messages: [ConversationItem] = []
    // Only the freshest visual evidence is replayed: a changed App must not
    // be judged from an older screenshot, and images dominate the budget.
    let latestMediaCallID = toolInvocations.last(where: { !$0.media.isEmpty })?.callID

    for entry in entries {
      switch entry {
      case .assistantText(let text):
        messages.append(
          ConversationItem(
            role: .assistant,
            content: [.text(text)],
            status: .completed
          ))
      case .runtimeNote(let note):
        messages.append(
          ConversationItem(
            role: .user,
            content: [.text("[runtime] \(note)")],
            status: .completed
          ))
      case .toolInvocation(let invocation):
        messages.append(
          contentsOf: invocationMessages(
            for: invocation,
            mode: mode,
            includesMedia: invocation.callID == latestMediaCallID
          ))
      }
    }
    return messages
  }

  private func invocationMessages(
    for invocation: ToolInvocation,
    mode: RenderingMode,
    includesMedia: Bool
  ) -> [ConversationItem] {
    var messages: [ConversationItem] = []
    let renderedArguments = invocation.renderedArguments ?? invocation.call.arguments
    switch mode {
    case .nativeToolCalls:
      messages.append(
        ConversationItem(
          role: .assistant,
          content: [
            ToolCallContentPart.part(
              for: ToolCallContentPart.FunctionCall(
                callID: invocation.callID,
                name: ToolFunctionName.sanitized(invocation.call.capabilityID),
                arguments: Self.argumentsJSON(renderedArguments)
              ))
          ],
          status: .completed
        ))
      messages.append(
        ConversationItem(
          role: .tool,
          content: [
            ToolCallContentPart.part(
              for: ToolCallContentPart.FunctionCallOutput(
                callID: invocation.callID,
                output: invocation.observation
              ))
          ],
          status: .completed
        ))
    case .textProtocol:
      messages.append(
        ConversationItem(
          role: .assistant,
          content: [
            .text(
              """
              {"type":"tool_call","tool":"\(invocation.call.capabilityID)","arguments":\
              \(Self.argumentsJSON(renderedArguments))}
              """)
          ],
          status: .completed
        ))
      messages.append(
        ConversationItem(
          role: .user,
          content: [
            .text("Observation from \(invocation.call.capabilityID):\n\(invocation.observation)")
          ],
          status: .completed
        ))
    }

    if includesMedia, !invocation.media.isEmpty {
      if acceptsImageInput {
        messages.append(
          ConversationItem(
            role: .user,
            content: [.text("Visual output of the tool call above:")] + invocation.media,
            status: .completed
          ))
      } else {
        // Say where the file is rather than attaching it. Sending an
        // image to a text-only model returns HTTP 400 for the entire
        // request — observed as a run dying immediately after its first
        // screenshot, with the game already built and running.
        let locations = invocation.media
          .compactMap { $0.uri ?? $0.fileURL?.path }
          .joined(separator: ", ")
        messages.append(
          ConversationItem(
            role: .user,
            content: [
              .text(
                """
                The tool call above produced visual output\(locations.isEmpty ? "" : " at \(locations)"). \
                This model cannot view images, so judge the result from the tool's textual output \
                and from semantic UI inspection rather than from the screenshot.
                """)
            ],
            status: .completed
          ))
      }
    }
    return messages
  }

  public static func argumentsJSON(_ arguments: [String: JSONValue]) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    guard let data = try? encoder.encode(arguments),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }

  // MARK: - Compaction

  private var renderedLength: Int {
    entries.reduce(0) { total, entry in
      switch entry {
      case .assistantText(let text):
        return total + text.count
      case .runtimeNote(let note):
        return total + note.count
      case .toolInvocation(let invocation):
        let arguments = invocation.renderedArguments ?? invocation.call.arguments
        // Observation bodies are the tool's already-filtered return.
        // Budget review does not count or rewrite them.
        return total + invocation.call.capabilityID.count
          + Self.argumentsJSON(arguments).count
      }
    }
  }

  public var exceedsBudget: Bool {
    renderedLength > maxCharacters
  }

  /// Frees budget without touching tool return bodies. Tools already filter
  /// their observations; a second pass that clipped those bodies hid cursors
  /// and made truncated reads look like finished work. Oversized *arguments*
  /// and older assistant prose are semantically compressed instead of dropped.
  /// Every tool call identity stays in place.
  public mutating func compactSemantically(
    task: String,
    compress: @Sendable (AgentContextCompressionRequest) async throws -> String
  ) async throws {
    guard exceedsBudget else { return }

    for index in entries.indices {
      guard exceedsBudget else { return }
      guard case .assistantText(let text) = entries[index],
        index < entries.count - 1,
        !text.hasPrefix("[Semantically compressed]"),
        text.count > elisionFloor
      else {
        continue
      }
      let target = min(400, max(elisionFloor, text.count / 4))
      let summary = try await compressedText(
        AgentContextCompressionRequest(
          kind: .assistantProse,
          source: text,
          targetCharacters: target,
          task: task
        ),
        compress: compress
      )
      entries[index] = .assistantText("[Semantically compressed] \(summary)")
    }

    for index in entries.indices {
      guard exceedsBudget else { return }
      guard case .toolInvocation(var invocation) = entries[index],
        index < entries.count - 2
      else {
        continue
      }
      guard invocation.renderedArguments == nil,
        Self.argumentsJSON(invocation.call.arguments).count > elisionFloor
      else {
        continue
      }
      invocation.renderedArguments = try await compressedArguments(
        invocation.call.arguments,
        task: task,
        compress: compress
      )
      invocation.isElided = true
      invocation.media = []
      entries[index] = .toolInvocation(invocation)
    }
  }

  private func compressedArguments(
    _ arguments: [String: JSONValue],
    task: String,
    compress: @Sendable (AgentContextCompressionRequest) async throws -> String
  ) async throws -> [String: JSONValue] {
    let identityKeys: Set<String> = [
      "path", "packagePath", "pluginID", "toolID", "action", "operation",
      "expectedOffset", "truncate", "query", "url",
    ]
    var result: [String: JSONValue] = [:]
    for (key, value) in arguments {
      if identityKeys.contains(key) {
        result[key] = value
        continue
      }
      switch value {
      case .string(let text) where text.count > elisionFloor:
        let summary = try await compressedText(
          AgentContextCompressionRequest(
            kind: .toolArguments,
            source: "\(key)=\(text)",
            targetCharacters: min(400, elisionFloor * 2),
            task: task
          ),
          compress: compress
        )
        result[key] = .string(summary)
      case .array, .object:
        let encoded = Self.argumentsJSON(["value": value])
        if encoded.count > elisionFloor {
          let summary = try await compressedText(
            AgentContextCompressionRequest(
              kind: .toolArguments,
              source: "\(key)=\(encoded)",
              targetCharacters: min(400, elisionFloor * 2),
              task: task
            ),
            compress: compress
          )
          result[key] = .string(summary)
        } else {
          result[key] = value
        }
      default:
        result[key] = value
      }
    }
    return result
  }

  private func compressedText(
    _ request: AgentContextCompressionRequest,
    compress: @Sendable (AgentContextCompressionRequest) async throws -> String
  ) async throws -> String {
    do {
      let summary = try await compress(request)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      if !summary.isEmpty {
        return summary
      }
    } catch is CancellationError {
      throw AgentError.cancelled
    } catch {
      if AgentToolFailure.isCancellation(error) { throw AgentError.cancelled }
      AgentLogCategory.capability.error(
        "agent context compression failed kind=\(request.kind.rawValue) "
          + "error=\(UserFacingErrorMapper.message(for: error))"
      )
    }
    return AgentContextCompressionFallback.extractive(
      request.source,
      targetCharacters: request.targetCharacters
    )
  }
}
