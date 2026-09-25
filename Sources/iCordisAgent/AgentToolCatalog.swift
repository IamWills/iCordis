import Foundation
import iCordisKernel

public struct AgentToolCatalog: Sendable {
  private let descriptors: [CapabilityDescriptor]

  public init(descriptors: [CapabilityDescriptor]) {
    var seenIDs: Set<String> = []
    self.descriptors = descriptors.filter { descriptor in
      descriptor.isEnabled && seenIDs.insert(descriptor.id).inserted
    }
  }

  public func descriptor(for capabilityID: String) -> CapabilityDescriptor? {
    descriptors.first { $0.id == capabilityID }
  }

  /// Maps a protocol function name back to the capability it was declared
  /// from. Tool declarations sanitize dotted capability IDs, so the name the
  /// model returns is not the ID the executor needs.
  public func capabilityID(forFunctionName name: String) -> String? {
    if descriptors.contains(where: { $0.id == name }) {
      return name
    }
    return descriptors.first { ToolFunctionName.sanitized($0.id) == name }?.id
  }

  public var allDescriptors: [CapabilityDescriptor] {
    descriptors
  }

  public func search(query: String, limit: Int) -> [CapabilityDescriptor] {
    let normalizedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    let cappedLimit = max(1, min(limit, 20))
    guard !normalizedQuery.isEmpty else {
      return Array(descriptors.prefix(cappedLimit))
    }

    let terms = searchTerms(for: normalizedQuery)
    return
      descriptors
      .map { descriptor in
        (descriptor, score(descriptor: descriptor, terms: terms, query: normalizedQuery))
      }
      .filter { $0.1 > 0 }
      .sorted { lhs, rhs in
        if lhs.1 == rhs.1 {
          return lhs.0.name.localizedCaseInsensitiveCompare(rhs.0.name) == .orderedAscending
        }
        return lhs.1 > rhs.1
      }
      .prefix(cappedLimit)
      .map(\.0)
  }

  public var renderedForPrompt: String {
    guard !descriptors.isEmpty else {
      return "No tools are currently available."
    }

    let rendered = descriptors.map { descriptor in
      let schema: JSONValue = .object([
        "type": .string(descriptor.schema.type),
        "properties": .object(descriptor.schema.properties),
        "required": .array(descriptor.schema.required.map(JSONValue.string)),
      ])
      return "- \(descriptor.id): \(descriptor.summary) Schema: \(compactJSON(schema))"
    }.joined(separator: "\n")
    return rendered
  }

  private func score(descriptor: CapabilityDescriptor, terms: [String], query: String) -> Int {
    let haystack = [
      descriptor.id,
      descriptor.name,
      descriptor.summary,
      descriptor.kind.rawValue,
      descriptor.metadata.values.compactMap(\.stringValue).joined(separator: " "),
    ].joined(separator: " ").lowercased()

    var score = 0
    if haystack.contains(query) {
      score += 8
    }
    for term in terms where haystack.contains(term) {
      score += 3
    }
    if descriptor.id.lowercased().contains(query) {
      score += 6
    }
    if descriptor.name.lowercased().contains(query) {
      score += 5
    }
    return score
  }

  /// Tool metadata is mostly English, while users commonly make the first
  /// discovery query in Chinese. A whole Chinese sentence has no whitespace
  /// tokens, so literal matching used to return nothing for requests such as
  /// “打开并测试app应用”. Keep this small and capability-oriented: it is query
  /// expansion for the tool index, not a general translation system.
  private func searchTerms(for query: String) -> [String] {
    var terms = query.split(whereSeparator: { $0.isWhitespace || $0 == "," || $0 == ";" })
      .map(String.init)
    let aliases: [(needle: String, expansions: [String])] = [
      ("打开", ["open", "launch", "show"]),
      ("应用", ["app", "apps"]),
      ("测试", ["test", "inspect", "ui"]),
      ("运行", ["run", "command"]),
      ("构建", ["build", "command"]),
      ("列表", ["list"]),
      ("列出", ["list"]),
      ("文件", ["file", "filesystem"]),
      ("代码", ["code", "workspace"]),
      ("网页", ["web", "network", "fetch"]),
      ("联网", ["network", "fetch"]),
      ("搜索", ["search", "find"]),
      ("会话", ["session", "conversation"]),
      ("设置", ["settings"]),
      ("模型", ["model"]),
      ("记忆", ["memory"]),
      ("技能", ["skill"]),
      ("截图", ["screenshot"]),
      ("点击", ["act", "press"]),
      ("工具", ["tool"]),
      ("插件", ["plugin", "plugins", "extension"]),
    ]
    for alias in aliases where query.contains(alias.needle) {
      terms.append(contentsOf: alias.expansions)
    }
    var seen: Set<String> = []
    return terms.filter { !$0.isEmpty && seen.insert($0).inserted }
  }

  private func compactJSON(_ value: JSONValue) -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    guard let data = try? encoder.encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return "{}"
    }
    return string
  }
}
