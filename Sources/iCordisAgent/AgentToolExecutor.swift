import Foundation
import iCordisKernel

public enum AgentToolFailureCategory: String, Sendable {
  case cancelled
  case timeout
  case unavailable
  case disabled
  case invalidArguments = "invalid_arguments"
  case permissionDenied = "permission_denied"
  case transport
  case invalidResponse = "invalid_response"
  case resourceLimit = "resource_limit"
  case reportedFailure = "reported_failure"
  case execution
}

public struct AgentToolFailure: Error, Sendable {
  public let code: String
  public let category: AgentToolFailureCategory
  public let message: String
  public let isRetryable: Bool
  public let suggestedAction: String
  public let underlyingType: String?
  public let sourceCode: String?

  public static func repeatedUnchangedCall(toolID: String) -> AgentToolFailure {
    AgentToolFailure(
      code: "tool.repeated_unchanged_call",
      category: .resourceLimit,
      message:
        "The tool call was blocked because the same request already returned the same successful observation twice.",
      isRetryable: false,
      suggestedAction:
        "Do not call \(toolID) again with unchanged arguments. Narrow or paginate the request, change the response format, use another source or tool, or finish from the observations already available.",
      underlyingType: nil,
      sourceCode: nil
    )
  }

  public static func codeRangeAlreadyRead(toolID: String, detail: String) -> AgentToolFailure {
    AgentToolFailure(
      code: "tool.code_range_already_read",
      category: .resourceLimit,
      message: detail,
      isRetryable: false,
      suggestedAction:
        "Use the reported next unread line, search for the required symbol, make a material change, or finish from existing evidence. Set refresh=true only when checking for an external file change.",
      underlyingType: nil,
      sourceCode: nil
    )
  }

  public static func inspectOnlyLimit(toolID: String) -> AgentToolFailure {
    AgentToolFailure(
      code: "tool.inspect_only_limit",
      category: .resourceLimit,
      message:
        "The run already completed four consecutive read/inspect operations without material progress.",
      isRetryable: false,
      suggestedAction:
        "Do not perform another inspection now. Use the existing observations to edit, run a targeted verification, provide a final answer, or explain the blocker.",
      underlyingType: nil,
      sourceCode: nil
    )
  }

  public static func capture(
    _ error: Error,
    toolID: String,
    timeout: TimeInterval,
    suggestedAction override: String? = nil
  ) -> AgentToolFailure {
    let category = category(for: error)
    let message: String
    if category == .timeout {
      message = "Tool call timed out after \(formatted(seconds: timeout))."
    } else {
      message = UserFacingErrorMapper.message(for: error)
    }
    return AgentToolFailure(
      code: code(for: category),
      category: category,
      message: bounded(message, limit: 4_000),
      isRetryable: retryable(category),
      suggestedAction: bounded(
        override ?? defaultSuggestedAction(for: category, toolID: toolID),
        limit: 1_000
      ),
      underlyingType: String(reflecting: type(of: error)),
      sourceCode: nil
    )
  }

  public static func reported(by result: CapabilityInvocationResult) -> AgentToolFailure {
    let errorObject = result.rawPayload?.agentToolObjectValue?["error"]?.agentToolObjectValue
    let message =
      errorObject?["message"]?.stringValue
      ?? result.content.compactMap(\.text).joined(separator: "\n").nonEmpty
      ?? "Tool returned success=false without an error message."
    // A remote tool's error payload is untrusted input. Preserve its code
    // for diagnostics, but never let it choose William's category or
    // suggested action because both influence the next model turn.
    let category = AgentToolFailureCategory.reportedFailure
    let code = self.code(for: category)
    let sourceCode = errorObject?["code"]?.stringValue.map { bounded($0, limit: 160) }
    let isRetryable = errorObject?["retryable"]?.agentToolBoolValue ?? retryable(category)
    return AgentToolFailure(
      code: code,
      category: category,
      message: bounded(message, limit: 4_000),
      isRetryable: isRetryable,
      suggestedAction: defaultSuggestedAction(for: category, toolID: result.capabilityID),
      underlyingType: nil,
      sourceCode: sourceCode
    )
  }

  public static func isCancellation(_ error: Error) -> Bool {
    if error is CancellationError { return true }
    if let agentError = error as? AgentError, case .cancelled = agentError { return true }
    if let urlError = error as? URLError, urlError.code == .cancelled { return true }
    let nsError = error as NSError
    return nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled
  }

  public func observation(toolID: String, argumentKeys: [String]) -> String {
    let keys = argumentKeys.isEmpty ? "none" : argumentKeys.sorted().joined(separator: ", ")
    let sourceCodeLine = sourceCode.map { "\nSource error code: \($0)" } ?? ""
    return """
      Tool call failed.
      Tool: \(toolID)
      Error code: \(code)
      Category: \(category.rawValue)
      Retryable: \(isRetryable ? "yes" : "no")
      Message: \(message)\(sourceCodeLine)
      Argument keys: \(keys)
      Suggested action: \(suggestedAction)
      """
  }

  public func payload(originalPayload: JSONValue?) -> JSONValue {
    var payload: [String: JSONValue] = [
      "code": .string(code),
      "category": .string(category.rawValue),
      "message": .string(message),
      "retryable": .bool(isRetryable),
      "suggested_action": .string(suggestedAction),
    ]
    if let underlyingType {
      payload["underlying_type"] = .string(underlyingType)
    }
    if let sourceCode {
      payload["source_code"] = .string(sourceCode)
    }
    var envelope: [String: JSONValue] = ["error": .object(payload)]
    if let originalPayload {
      envelope["tool_payload"] = originalPayload
    }
    return .object(envelope)
  }

  private static func category(for error: Error) -> AgentToolFailureCategory {
    if isCancellation(error) { return .cancelled }
    if error is AgentToolTimeoutError { return .timeout }
    if let mcpError = error as? MCPError {
      switch mcpError {
      case .timeout: return .timeout
      case .unavailableServer: return .unavailable
      case .invocationFailed: return .execution
      }
    }
    if let agentError = error as? AgentError {
      switch agentError {
      case .toolUnavailable: return .unavailable
      case .maxToolCallsExceeded, .maxIterationsExceeded: return .resourceLimit
      case .cancelled: return .cancelled
      case .invalidAction: return .invalidArguments
      case .emptyTask, .disabled: return .disabled
      }
    }
    if let capabilityError = error as? CapabilityInvocationError {
      switch capabilityError {
      case .capabilityDisabled: return .disabled
      case .unsupportedTarget: return .unavailable
      case .routingFailed: return .transport
      }
    }
    if let skillError = error as? SkillError {
      switch skillError {
      case .notFound: return .unavailable
      case .invocationFailed: return .execution
      }
    }
    if error is ValidationError { return .invalidArguments }
    if error is DecodingError || error is EncodingError { return .invalidResponse }
    if let urlError = error as? URLError {
      switch urlError.code {
      case .timedOut: return .timeout
      case .cancelled: return .cancelled
      case .noPermissionsToReadFile: return .permissionDenied
      case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed,
        .networkConnectionLost, .notConnectedToInternet,
        .internationalRoamingOff, .callIsActive,
        .dataNotAllowed, .secureConnectionFailed:
        return .transport
      default:
        return .execution
      }
    }
    let nsError = error as NSError
    if nsError.domain == NSCocoaErrorDomain,
      [NSFileReadNoPermissionError, NSFileWriteNoPermissionError].contains(nsError.code)
    {
      return .permissionDenied
    }
    return .execution
  }

  private static func code(for category: AgentToolFailureCategory) -> String {
    "tool.\(category.rawValue)"
  }

  private static func retryable(_ category: AgentToolFailureCategory) -> Bool {
    switch category {
    case .timeout, .transport, .invalidArguments, .invalidResponse:
      true
    case .cancelled, .unavailable, .disabled, .permissionDenied,
      .resourceLimit, .reportedFailure, .execution:
      false
    }
  }

  private static func defaultSuggestedAction(
    for category: AgentToolFailureCategory,
    toolID: String
  ) -> String {
    switch category {
    case .cancelled:
      "Stop the current run unless the user explicitly asks to continue."
    case .timeout:
      "Retry once with a smaller scope or shorter payload, then choose an alternative tool if it times out again."
    case .unavailable:
      "Search for an alternative capability instead of repeatedly calling \(toolID)."
    case .disabled:
      "Use an enabled alternative or explain which capability must be enabled by the user."
    case .invalidArguments:
      "Review the tool schema and retry with corrected, minimal arguments."
    case .permissionDenied:
      "Request the required user authorization or operate only within an already authorized scope."
    case .transport:
      "Verify the endpoint or connection and retry once; use an alternative source if the failure persists."
    case .invalidResponse:
      "Retry once with a simpler response format, then use another tool if decoding still fails."
    case .resourceLimit:
      "Do not make another tool call; answer from existing observations and clearly state any remaining limitation."
    case .reportedFailure:
      "Inspect the returned failure details, correct the request if possible, or choose an alternative tool."
    case .execution:
      "Inspect the error, avoid repeating the identical call, and try a corrected or alternative approach."
    }
  }

  private static func formatted(seconds: TimeInterval) -> String {
    String(format: "%.2fs", max(seconds, 0))
  }

  private static func bounded(_ value: String, limit: Int) -> String {
    guard value.count > limit else { return value }
    return String(value.prefix(limit)) + "… [truncated]"
  }

  public init(
    code: String, category: AgentToolFailureCategory, message: String, isRetryable: Bool,
    suggestedAction: String, underlyingType: String? = nil, sourceCode: String? = nil
  ) {
    self.code = code
    self.category = category
    self.message = message
    self.isRetryable = isRetryable
    self.suggestedAction = suggestedAction
    self.underlyingType = underlyingType
    self.sourceCode = sourceCode
  }
}

public enum AgentToolInvocationOutcome: Sendable {
  case success(CapabilityExecutionTrace)
  case failure(trace: CapabilityExecutionTrace, failure: AgentToolFailure)

  public static func classify(_ trace: CapabilityExecutionTrace) -> AgentToolInvocationOutcome {
    guard trace.result.success == false else { return .success(trace) }
    return .failure(trace: trace, failure: .reported(by: trace.result))
  }
}

public actor AgentToolExecutor {
  private let orchestrator: any CapabilityInvoking
  private let settings: AppSettings
  private let catalog: AgentToolCatalog
  private let builtinRegistry: any AgentBuiltinToolProviding
  private let currentSession: ConversationSession
  private let timeout: TimeInterval

  /// Session state can change during a run — most importantly, the user can
  /// pick a working directory through `william.app.user_action`. Tools that
  /// read the session must see that, or they re-prompt forever.
  public nonisolated func withCurrentSession(_ session: ConversationSession) -> AgentToolExecutor {
    AgentToolExecutor(
      orchestrator: orchestrator,
      settings: settings,
      catalog: catalog,
      builtinRegistry: builtinRegistry,
      currentSession: session,
      timeout: timeout
    )
  }

  public init(
    orchestrator: any CapabilityInvoking,
    settings: AppSettings,
    catalog: AgentToolCatalog,
    builtinRegistry: any AgentBuiltinToolProviding,
    currentSession: ConversationSession,
    timeout: TimeInterval
  ) {
    self.orchestrator = orchestrator
    self.settings = settings
    self.catalog = catalog
    self.builtinRegistry = builtinRegistry
    self.currentSession = currentSession
    self.timeout = timeout
  }

  /// All non-cancellation failures cross this boundary as a typed failure
  /// outcome. This keeps the agent loop alive and gives it enough structured
  /// context to decide whether to repair, retry, switch tools, or stop.
  public func invoke(_ toolCall: AgentToolCall, sessionID: UUID) async throws
    -> AgentToolInvocationOutcome
  {
    let descriptor = catalog.descriptor(for: toolCall.capabilityID)
    var arguments = toolCall.arguments
    if descriptor?.kind == .mcpTool,
      arguments["_server"] == nil,
      let serverID = descriptor?.metadata["serverID"]?.stringValue
    {
      arguments["_server"] = .string(serverID)
    }
    let request = CapabilityInvocationRequest(
      sessionID: sessionID,
      capabilityID: toolCall.capabilityID,
      arguments: arguments,
      initiatedBy: .assistant,
      timeout: timeout
    )
    let startedAt = Date()
    let builtinRegistry = self.builtinRegistry
    let catalog = self.catalog
    let currentSession = self.currentSession
    let orchestrator = self.orchestrator
    let settings = self.settings

    do {
      let trace = try await withTimeout(seconds: timeout) {
        // Capability identity, not its namespace, owns routing.
        // Plugin administration deliberately uses `william.plugins.*`
        // IDs but is implemented by PluginToolIDs. Routing
        // every `william.*` call to the builtin registry made those
        // declared tools fail as unavailable at execution time.
        if descriptor?.kind == .builtin
          || (descriptor == nil && toolCall.capabilityID.hasPrefix("william."))
        {
          return try await builtinRegistry.invoke(
            request,
            catalog: catalog,
            currentSession: currentSession
          )
        }
        if descriptor == nil, !toolCall.capabilityID.hasPrefix("skill.") {
          throw AgentError.toolUnavailable(toolCall.capabilityID)
        }
        return try await orchestrator.executeCapability(request, settings: settings)
      }
      return AgentToolInvocationOutcome.classify(trace)
    } catch {
      if AgentToolFailure.isCancellation(error) || Task.isCancelled {
        throw CancellationError()
      }
      let finishedAt = Date()
      let failure = AgentToolFailure.capture(
        error,
        toolID: toolCall.capabilityID,
        timeout: timeout
      )
      let trace = CapabilityExecutionTrace(
        id: UUID(),
        request: request,
        result: CapabilityInvocationResult(
          capabilityID: toolCall.capabilityID,
          success: false,
          content: [.text(failure.message)],
          rawPayload: failure.payload(originalPayload: nil),
          latency: finishedAt.timeIntervalSince(startedAt)
        ),
        startedAt: startedAt,
        finishedAt: finishedAt
      )
      return .failure(trace: trace, failure: failure)
    }
  }

  /// Uses an unstructured race so a non-cooperative tool cannot keep the
  /// caller trapped inside a task-group scope after the timeout has fired.
  private func withTimeout<T: Sendable>(
    seconds: TimeInterval,
    operation: @escaping @Sendable () async throws -> T
  ) async throws -> T {
    let safeSeconds = seconds.isFinite ? max(seconds, 0.1) : 30
    let nanoseconds = UInt64(min(safeSeconds, 86_400) * 1_000_000_000)
    let race = AgentToolInvocationRace<T>()
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        race.install(continuation)
        let operationTask = Task {
          do {
            race.resolve(.success(try await operation()))
          } catch {
            race.resolve(.failure(error))
          }
        }
        let timeoutTask = Task {
          do {
            try await Task.sleep(nanoseconds: nanoseconds)
          } catch {
            return
          }
          race.resolve(.failure(AgentToolTimeoutError()))
        }
        race.setTasks(operation: operationTask, timeout: timeoutTask)
      }
    } onCancel: {
      race.resolve(.failure(CancellationError()))
    }
  }
}

private struct AgentToolTimeoutError: Error, Sendable {}

private final class AgentToolInvocationRace<Value: Sendable>: @unchecked Sendable {
  private let lock = NSLock()
  private var continuation: CheckedContinuation<Value, Error>?
  private var pendingResult: Result<Value, Error>?
  private var operationTask: Task<Void, Never>?
  private var timeoutTask: Task<Void, Never>?
  private var isResolved = false

  func install(_ continuation: CheckedContinuation<Value, Error>) {
    lock.lock()
    if let pendingResult {
      self.pendingResult = nil
      lock.unlock()
      continuation.resume(with: pendingResult)
      return
    }
    self.continuation = continuation
    lock.unlock()
  }

  func setTasks(operation: Task<Void, Never>, timeout: Task<Void, Never>) {
    lock.lock()
    if isResolved {
      lock.unlock()
      operation.cancel()
      timeout.cancel()
      return
    }
    operationTask = operation
    timeoutTask = timeout
    lock.unlock()
  }

  func resolve(_ result: Result<Value, Error>) {
    lock.lock()
    guard isResolved == false else {
      lock.unlock()
      return
    }
    isResolved = true
    let continuation = self.continuation
    self.continuation = nil
    if continuation == nil {
      pendingResult = result
    }
    let operationTask = self.operationTask
    let timeoutTask = self.timeoutTask
    self.operationTask = nil
    self.timeoutTask = nil
    lock.unlock()

    operationTask?.cancel()
    timeoutTask?.cancel()
    continuation?.resume(with: result)
  }
}

extension String {
  fileprivate var nonEmpty: String? {
    let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
    return trimmed.isEmpty ? nil : trimmed
  }
}

extension JSONValue {
  fileprivate var agentToolObjectValue: [String: JSONValue]? {
    guard case .object(let value) = self else { return nil }
    return value
  }

  fileprivate var agentToolBoolValue: Bool? {
    guard case .bool(let value) = self else { return nil }
    return value
  }
}
