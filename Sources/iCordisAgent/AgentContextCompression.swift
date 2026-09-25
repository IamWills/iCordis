import Foundation
import iCordisKernel

public enum AgentContextCompressionKind: String, Sendable {
  case conversationHistory
  case assistantProse
  case toolArguments
}

public struct AgentContextCompressionRequest: Sendable {
  public var kind: AgentContextCompressionKind
  public var source: String
  public var targetCharacters: Int
  public var task: String

  public init(
    kind: AgentContextCompressionKind, source: String, targetCharacters: Int, task: String
  ) {
    self.kind = kind
    self.source = source
    self.targetCharacters = targetCharacters
    self.task = task
  }
}

public struct AgentContextCompressionParser: Sendable {
  public func parse(_ text: String) throws -> String {
    if let object = firstDecodedJSONObject(from: text),
      let summary = object["summary"]?.stringValue?
        .trimmingCharacters(in: .whitespacesAndNewlines),
      !summary.isEmpty
    {
      return summary
    }
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      throw AgentError.invalidAction("expected a context-compression summary")
    }
    return trimmed
  }

  public init() {}
}

public enum AgentContextCompressionFallback {
  /// Last-resort extractive shrink when the lightweight compressor is unavailable.
  /// Keeps opening and closing sentences instead of a single prefix cut.
  public static func extractive(_ text: String, targetCharacters: Int) -> String {
    let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
    let budget = max(80, targetCharacters)
    guard normalized.count > budget else { return normalized }

    let parts = sentences(in: normalized)
    guard parts.count >= 2 else {
      let head = String(normalized.prefix(budget / 2))
      let tail = String(normalized.suffix(budget / 2))
      return "\(head)\n…\n\(tail)"
    }

    var leading: [String] = []
    var trailing: [String] = []
    var used = 1
    var start = 0
    var end = parts.count - 1
    while start <= end {
      let takeLeading = leading.count <= trailing.count
      let next = takeLeading ? parts[start] : parts[end]
      if used + next.count + 1 > budget, !leading.isEmpty || !trailing.isEmpty {
        break
      }
      if takeLeading {
        leading.append(next)
        start += 1
      } else {
        trailing.insert(next, at: 0)
        end -= 1
      }
      used += next.count + 1
    }
    return (leading + ["…"] + trailing).joined(separator: " ")
  }

  private static func sentences(in text: String) -> [String] {
    let separators = CharacterSet(charactersIn: ".!?。！？\n")
    return
      text
      .components(separatedBy: separators)
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
  }
}
