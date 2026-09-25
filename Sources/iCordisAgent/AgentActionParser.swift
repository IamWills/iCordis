import Foundation
import iCordisKernel

public struct AgentActionParser: Sendable {
  public func parse(_ text: String) throws -> AgentAction {
    try parse(text, allowsNaturalLanguageFinalAnswer: true)
  }

  public func parse(_ text: String, allowsNaturalLanguageFinalAnswer: Bool) throws -> AgentAction {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AgentError.invalidAction("empty model output")
    }

    let jsonCandidates = extractJSONObjects(from: trimmed)
    guard !jsonCandidates.isEmpty else {
      if allowsNaturalLanguageFinalAnswer, shouldTreatUndecodableTextAsFinalAnswer(trimmed) {
        return .finalAnswer(trimmed)
      }
      if allowsNaturalLanguageFinalAnswer, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") {
        return .finalAnswer(trimmed)
      }
      throw AgentError.invalidAction("expected a JSON object")
    }

    let value: JSONValue
    if let decoded = Self.firstDecodedJSONValue(from: jsonCandidates) {
      value = decoded
    } else if allowsNaturalLanguageFinalAnswer, shouldTreatUndecodableTextAsFinalAnswer(trimmed) {
      return .finalAnswer(trimmed)
    } else if allowsNaturalLanguageFinalAnswer, !trimmed.hasPrefix("{"), !trimmed.hasPrefix("[") {
      return .finalAnswer(trimmed)
    } else {
      throw AgentError.invalidAction("expected a JSON object")
    }

    guard case .object(let object) = value else {
      throw AgentError.invalidAction("missing type")
    }

    let type = normalizedType(from: object)
    switch type {
    case "final_answer":
      guard
        let content = object["content"]?.stringValue
          ?? object["answer"]?.stringValue
          ?? object["final"]?.stringValue
          ?? object["response"]?.stringValue
          ?? object["message"]?.stringValue,
        !content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      else {
        throw AgentError.invalidAction("final_answer requires non-empty content")
      }
      return .finalAnswer(content)
    case "tool_call":
      let tool =
        object["tool"]?.stringValue
        ?? object["tool_name"]?.stringValue
        ?? object["name"]?.stringValue
        ?? object["capabilityID"]?.stringValue
        ?? object["capability_id"]?.stringValue
      guard let tool, !tool.isEmpty else {
        throw AgentError.invalidAction("tool_call requires tool")
      }
      let arguments: [String: JSONValue]
      if case .object(let parsedArguments)? = object["arguments"] {
        arguments = parsedArguments
      } else {
        arguments = [:]
      }
      return .toolCall(
        AgentToolCall(
          capabilityID: tool,
          arguments: arguments,
          rationale: object["rationale"]?.stringValue
        ))
    case "search_tools":
      let query =
        object["query"]?.stringValue
        ?? object["q"]?.stringValue
        ?? object["capability"]?.stringValue
        ?? object["need"]?.stringValue
        ?? object["thought"]?.stringValue
        ?? object["reasoning"]?.stringValue
        ?? object["plan"]?.stringValue
        ?? object["description"]?.stringValue
        ?? "tools"
      var arguments: [String: JSONValue] = ["query": .string(query)]
      if let limit = object["limit"] {
        arguments["limit"] = limit
      }
      return .toolCall(
        AgentToolCall(
          capabilityID: AgentBuiltinToolID.searchTools,
          arguments: arguments,
          rationale: object["rationale"]?.stringValue
        ))
    case "missing_type":
      return .toolCall(
        AgentToolCall(
          capabilityID: AgentBuiltinToolID.searchTools,
          arguments: ["query": .string(fallbackSearchQuery(from: object))],
          rationale: object["thought"]?.stringValue ?? object["reasoning"]?.stringValue
        ))
    default:
      throw AgentError.invalidAction("unsupported type \(type)")
    }
  }

  private func normalizedType(from object: [String: JSONValue]) -> String {
    if let raw = object["type"]?.stringValue ?? object["action"]?.stringValue {
      let normalized = raw.lowercased().replacingOccurrences(of: "-", with: "_")
      if ["final", "answer", "final_answer", "respond", "response"].contains(normalized) {
        return "final_answer"
      }
      if ["tool", "tool_call", "call_tool", "function", "function_call"].contains(normalized) {
        return "tool_call"
      }
      if ["search", "search_tool", "search_tools", "find_tool", "find_tools"].contains(normalized) {
        return "search_tools"
      }
      return normalized
    }
    if object["tool"] != nil || object["tool_name"] != nil || object["name"] != nil
      || object["capabilityID"] != nil || object["capability_id"] != nil
    {
      return "tool_call"
    }
    if object["query"] != nil || object["q"] != nil || object["capability"] != nil
      || object["need"] != nil
    {
      return "search_tools"
    }
    if object["content"] != nil || object["answer"] != nil || object["final"] != nil
      || object["response"] != nil || object["message"] != nil
    {
      return "final_answer"
    }
    return "missing_type"
  }

  private func fallbackSearchQuery(from object: [String: JSONValue]) -> String {
    let preferredKeys = ["thought", "reasoning", "plan", "description", "intent", "goal", "task"]
    for key in preferredKeys {
      if let value = object[key]?.stringValue,
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      {
        return String(value.prefix(160))
      }
    }
    let keys = object.keys.sorted()
    if !keys.isEmpty {
      return keys.joined(separator: " ")
    }
    return "available tools"
  }

  private func shouldTreatUndecodableTextAsFinalAnswer(_ text: String) -> Bool {
    let lowercased = text.lowercased()
    if lowercased.contains("```")
      || lowercased.contains("<!doctype")
      || lowercased.contains("<html")
      || lowercased.contains("<script")
      || lowercased.contains("<style")
    {
      return true
    }

    guard text.contains("\n") else { return false }
    let codeSignals = [
      "body {",
      "@keyframes",
      "function ",
      "const ",
      "let ",
      "var ",
      "document.",
      "addeventlistener",
      "requestanimationframe",
      "canvas",
    ]
    return codeSignals.contains { lowercased.contains($0) }
  }

  private static func firstDecodedJSONValue(from candidates: [String]) -> JSONValue? {
    let decoder = JSONDecoder()
    for candidate in candidates {
      guard let data = candidate.data(using: .utf8),
        let value = try? decoder.decode(JSONValue.self, from: data)
      else {
        continue
      }
      return value
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
      } else {
        if character == "\"" {
          isInsideString = true
        } else if character == "{" {
          depth += 1
        } else if character == "}" {
          depth -= 1
          if depth == 0 {
            return String(text[start...index])
          }
        }
      }

      index = text.index(after: index)
    }

    return nil
  }

  public init() {}
}
