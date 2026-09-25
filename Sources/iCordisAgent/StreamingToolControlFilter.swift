import Foundation
import iCordisKernel

/// Canonical vocabulary for model-generated tool control markup. Keeping this
/// at the protocol boundary prevents the agent and chat presentation layers from
/// drifting into separate, incomplete marker lists.
public enum ToolControlMarkup {
  public static let openMarkers = [
    "<william:tool_call",
    "<william:tool_use",
    "<tool_call",
    "<tool_calls",
    "<tool>",
    "<|tool",
    "<｜tool",
    "<｜｜DSML",
    "assistant to=william:tool_call",
    "analysis to=william:tool_call",
    "commentary to=william:tool_call",
    "to=william:tool_call",
    "william:tool_call",
  ]

  public static let closeMarkers = [
    "</william:tool_call>",
    "</william:tool_use>",
    "</tool_call>",
    "</tool_calls>",
    "</tool>",
    "</｜｜DSML｜｜l_call>",
    "</｜｜DSML｜｜tool_call>",
    "<|tool_call_end|>",
    "<|tool_calls_end|>",
    "<｜tool▁calls▁end｜>",
  ]

  public static func isIncompleteOpenMarker(_ text: Substring) -> Bool {
    let candidate = text.lowercased()
    guard candidate.isEmpty == false else { return false }
    return openMarkers.contains { marker in
      let normalizedMarker = marker.lowercased()
      return candidate.count < normalizedMarker.count
        && normalizedMarker.hasPrefix(candidate)
    }
  }
}

/// Append-only filter for tool routing/control markup embedded in model text.
/// It deliberately retains partial marker suffixes between chunks so a prefix
/// such as `<tool` or `william:tool_call` is never rendered and later retracted.
public struct StreamingToolControlFilter {
  private var pending = ""
  private var isSuppressingControlPayload = false

  public mutating func consume(_ chunk: String) -> [String] {
    guard chunk.isEmpty == false else { return [] }
    pending += chunk
    var output = ""

    while pending.isEmpty == false {
      if isSuppressingControlPayload {
        guard let closeRange = firstCloseMarker(in: pending) else {
          pending =
            retainedMarkerPrefixSuffix(in: pending, markers: ToolControlMarkup.closeMarkers) ?? ""
          return output.isEmpty ? [] : [output]
        }
        pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
        isSuppressingControlPayload = false
        continue
      }

      if let closeRange = leadingCloseMarker(in: pending) {
        pending.removeSubrange(pending.startIndex..<closeRange.upperBound)
        continue
      }

      guard let openRange = firstOpenMarker(in: pending) else {
        let retained =
          retainedMarkerPrefixSuffix(in: pending, markers: ToolControlMarkup.openMarkers) ?? ""
        let emitEnd = pending.index(pending.endIndex, offsetBy: -retained.count)
        output += pending[..<emitEnd]
        pending = retained
        return output.isEmpty ? [] : [output]
      }

      output += pending[..<openRange.lowerBound]
      pending.removeSubrange(pending.startIndex..<openRange.upperBound)
      isSuppressingControlPayload = true
    }

    return output.isEmpty ? [] : [output]
  }

  public mutating func finish() -> String? {
    defer {
      pending.removeAll(keepingCapacity: true)
      isSuppressingControlPayload = false
    }
    guard !isSuppressingControlPayload else { return nil }
    let clean = ToolControlMarkup.closeMarkers.reduce(pending) { partial, marker in
      partial.replacingOccurrences(of: marker, with: "", options: [.caseInsensitive])
    }
    return clean.isEmpty ? nil : clean
  }

  private func firstOpenMarker(in text: String) -> Range<String.Index>? {
    ToolControlMarkup.openMarkers.compactMap { marker -> Range<String.Index>? in
      guard let markerRange = text.range(of: marker, options: [.caseInsensitive]) else {
        return nil
      }
      let start = markerRange.lowerBound

      // Routing labels and special-token sentinels are complete markers by
      // themselves; XML-style markers extend through their closing `>`.
      if marker.lowercased().contains("william:tool_call") && marker.hasPrefix("<") == false
        || text[start...].hasPrefix("<｜｜")
        || text[start...].hasPrefix("<||")
      {
        return markerRange
      }
      guard let end = text[start...].firstIndex(of: ">") else {
        return start..<text.endIndex
      }
      return start..<text.index(after: end)
    }
    .min { $0.lowerBound < $1.lowerBound }
  }

  private func firstCloseMarker(in text: String) -> Range<String.Index>? {
    ToolControlMarkup.closeMarkers.compactMap { text.range(of: $0, options: [.caseInsensitive]) }
      .min { $0.lowerBound < $1.lowerBound }
  }

  private func leadingCloseMarker(in text: String) -> Range<String.Index>? {
    ToolControlMarkup.closeMarkers
      .compactMap { text.range(of: $0, options: [.caseInsensitive]) }
      .first { $0.lowerBound == text.startIndex }
  }

  private func retainedMarkerPrefixSuffix(in text: String, markers: [String]) -> String? {
    let lowercasedText = text.lowercased()
    return
      markers
      .flatMap { marker in
        let lowercasedMarker = marker.lowercased()
        return (1...min(lowercasedMarker.count, text.count)).compactMap { length -> String? in
          let suffix = String(lowercasedText.suffix(length))
          guard length < lowercasedMarker.count, lowercasedMarker.hasPrefix(suffix) else {
            return nil
          }
          return String(text.suffix(length))
        }
      }
      .max { $0.count < $1.count }
  }

  public init() {}
}
