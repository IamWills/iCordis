import Foundation
import iCordisKernel

public struct AgentToolResultFormatter: Sendable {
  public let maxCharacters: Int

  public func observation(from trace: CapabilityExecutionTrace) -> String {
    let text = trace.result.content.compactMap(\.text).joined(separator: "\n")
    let raw = trace.result.rawPayload.map(renderJSONValue) ?? ""
    let body: String
    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      body = text
    } else if !raw.isEmpty {
      body = raw
    } else {
      body = trace.result.success ? "Tool completed successfully." : "Tool returned no content."
    }
    // Tools already filter and paginate their returns. A second character
    // budget here hid continuation cursors and treated messy payloads as
    // something the trajectory should rewrite.
    return body
  }

  public func observation(
    from failure: AgentToolFailure,
    toolID: String,
    argumentKeys: [String]
  ) -> String {
    truncated(failure.observation(toolID: toolID, argumentKeys: argumentKeys))
  }

  private func truncated(_ text: String) -> String {
    guard text.count > maxCharacters else { return text }
    return String(text.prefix(maxCharacters)) + "\n[Observation truncated]"
  }

  private func renderJSONValue(_ value: JSONValue) -> String {
    guard let data = try? JSONEncoder().encode(value),
      let string = String(data: data, encoding: .utf8)
    else {
      return ""
    }
    return string
  }

  public init(maxCharacters: Int) { self.maxCharacters = maxCharacters }
}
