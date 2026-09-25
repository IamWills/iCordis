import Foundation
import iCordisKernel

public enum AgentCompletionStatus: String, Codable, Sendable, Hashable {
  case `continue`, completed
  case needsUser = "needs_user"
  case blocked
}

public struct AgentCompletionDecision: Sendable, Hashable {
  public var shouldContinue: Bool
  public var reason: String?
  public var status: AgentCompletionStatus = .completed
  public var nextAction: String? = nil

  public static let schema: JSONValue = .object([
    "type": .string("object"),
    "properties": .object([
      "status": .object([
        "type": .string("string"),
        "enum": .array(
          ["continue", "completed", "needs_user", "blocked"].map(JSONValue.string)
        ),
      ]),
      "reason": .object(["type": .string("string")]),
      "next_action": .object(["type": .string("string")]),
    ]),
    "required": .array(["status", "reason", "next_action"].map(JSONValue.string)),
    "additionalProperties": .bool(false),
  ])

  public init(
    shouldContinue: Bool, reason: String? = nil, status: AgentCompletionStatus = .completed,
    nextAction: String? = nil
  ) {
    self.shouldContinue = shouldContinue
    self.reason = reason
    self.status = status
    self.nextAction = nextAction
  }
}

/// Classifies an announce-only turn by size only. A one-line progress sentence
/// still deserves one chance to call a tool. A long no-tool-call essay is
/// already a stalled turn — the runtime does not inspect its wording.
public enum AgentAnnounceStall: Sendable, Equatable {
  case shortProgress
  case longAnnouncement

  public var runStopKind: AgentRunStopKind {
    switch self {
    case .shortProgress:
      return .repeatedEmptyAnnouncement
    case .longAnnouncement:
      return .longEmptyAnnouncement
    }
  }
}

public enum AgentRunStopKind: String, Sendable, Equatable {
  case repeatedEmptyAnnouncement
  case longEmptyAnnouncement

  public var runtimeFact: String {
    switch self {
    case .repeatedEmptyAnnouncement:
      return
        "The run stopped after consecutive turns that only announced a next step and called no tool."
    case .longEmptyAnnouncement:
      return "The run stopped after a long announce-only turn that called no tool."
    }
  }
}

public struct AgentAnnounceStallDetector: Sendable {
  /// Above a single progress line. The native contract asks for at most one
  /// short sentence beside a tool call; a no-tool-call turn this long is the
  /// tool call's substitute, not a preface.
  public static let longAnnouncementCharacterLimit = 500

  public func classify(_ text: String) -> AgentAnnounceStall {
    let length = text.trimmingCharacters(in: .whitespacesAndNewlines).count
    return length >= Self.longAnnouncementCharacterLimit
      ? .longAnnouncement
      : .shortProgress
  }

  public init() {}
}

public struct AgentRunStopMessageParser: Sendable {
  public func parse(_ text: String) throws -> String {
    if let object = firstDecodedJSONObject(from: text),
      let message = object["message"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !message.isEmpty
    {
      return message
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AgentError.invalidAction("expected a run-stop message")
    }
    return trimmed
  }

  public init() {}
}

public struct AgentCompletionDecisionParser: Sendable {
  public func parse(_ text: String) throws -> AgentCompletionDecision {
    guard let object = firstDecodedJSONObject(from: text) else {
      throw AgentError.invalidAction("expected a JSON completion decision")
    }

    let reason = object["reason"]?.stringValue ?? object["rationale"]?.stringValue
    if let rawStatus = object["status"]?.stringValue {
      guard let status = AgentCompletionStatus(rawValue: rawStatus) else {
        throw AgentError.invalidAction("unsupported completion status \(rawStatus)")
      }
      let next = object["next_action"]?.stringValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      if status == .continue, next?.isEmpty != false {
        return AgentCompletionDecision(
          shouldContinue: false,
          reason: "No concrete next action; waiting for user follow-up.", status: .needsUser)
      }
      return AgentCompletionDecision(
        shouldContinue: status == .continue,
        reason: reason, status: status, nextAction: next)
    }

    if let shouldContinue = boolValue(object["should_continue"])
      ?? boolValue(object["shouldContinue"])
      ?? boolValue(object["continue"])
    {
      return AgentCompletionDecision(shouldContinue: shouldContinue, reason: reason)
    }
    // Keep compatibility with the former loop-controller response shape.
    if let shouldStop = boolValue(object["should_stop"])
      ?? boolValue(object["shouldStop"])
      ?? boolValue(object["stop"])
    {
      return AgentCompletionDecision(shouldContinue: !shouldStop, reason: reason)
    }

    let rawDecision =
      object["decision"]?.stringValue
      ?? object["type"]?.stringValue
      ?? object["action"]?.stringValue
      ?? ""
    let decision = rawDecision.lowercased().replacingOccurrences(of: "-", with: "_")
    if ["continue", "continue_loop", "keep_working", "use_tool"].contains(decision) {
      return AgentCompletionDecision(shouldContinue: true, reason: reason)
    }
    if ["stop", "finish", "complete", "final_answer"].contains(decision) {
      return AgentCompletionDecision(shouldContinue: false, reason: reason)
    }
    throw AgentError.invalidAction("unsupported completion decision \(decision)")
  }

  private func boolValue(_ value: JSONValue?) -> Bool? {
    guard case .bool(let value)? = value else { return nil }
    return value
  }

  public init() {}
}

public func firstDecodedJSONObject(from text: String) -> [String: JSONValue]? {
  let decoder = JSONDecoder()
  for candidate in extractJSONObjects(from: text) {
    guard let data = candidate.data(using: .utf8),
      let value = try? decoder.decode(JSONValue.self, from: data),
      case .object(let object) = value
    else {
      continue
    }
    return object
  }
  return nil
}

private func extractJSONObjects(from text: String) -> [String] {
  var candidates: [String] = []
  var searchStart = text.startIndex
  while let start = text[searchStart...].firstIndex(of: "{") {
    if let json = firstBalancedJSONObject(in: String(text[start...])) {
      candidates.append(json)
    }
    searchStart = text.index(after: start)
  }
  return candidates
}

private func firstBalancedJSONObject(in text: String) -> String? {
  guard let start = text.firstIndex(of: "{") else { return nil }
  var depth = 0
  var isInsideString = false
  var isEscaping = false
  var index = start

  while index < text.endIndex {
    let character = text[index]
    if isInsideString {
      if isEscaping {
        isEscaping = false
      } else if character == "\\" {
        isEscaping = true
      } else if character == "\"" {
        isInsideString = false
      }
    } else if character == "\"" {
      isInsideString = true
    } else if character == "{" {
      depth += 1
    } else if character == "}" {
      depth -= 1
      if depth == 0 {
        return String(text[start...index])
      }
    }
    index = text.index(after: index)
  }
  return nil
}
