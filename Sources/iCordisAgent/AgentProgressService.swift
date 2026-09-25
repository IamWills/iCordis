import CryptoKit
import Foundation
import iCordisKernel

public struct AgentProgressTurn: Codable, Sendable, Hashable {
  public var text: String
  public var toolCalls: [String]
  public var toolResults: [String]
  public static func fingerprint(_ text: String) -> String {
    SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
  }

  public init(text: String, toolCalls: [String], toolResults: [String]) {
    self.text = text
    self.toolCalls = toolCalls
    self.toolResults = toolResults
  }
}

public struct AgentProgressService: WilliamService {
  public let summarize: @Sendable ([AgentProgressTurn]) -> String
  public static let standard = AgentProgressService { turns in
    guard let latest = turns.last else { return "No working turns recorded." }
    let previous = turns.dropLast()
    let repeatedText = previous.filter { $0.text == latest.text }.count
    let repeatedCalls =
      latest.toolCalls.isEmpty ? 0 : previous.filter { $0.toolCalls == latest.toolCalls }.count
    let repeatedResults =
      latest.toolResults.isEmpty
      ? 0 : previous.filter { $0.toolResults == latest.toolResults }.count
    return
      "Recent working turns=\(turns.count); latest text seen before=\(repeatedText); same tool calls seen before=\(repeatedCalls); same tool results seen before=\(repeatedResults). These are evidence signals only, not a stopping rule. Judge semantic progress; if uncertain, end and wait for user follow-up."
  }

  public init(summarize: @escaping @Sendable ([AgentProgressTurn]) -> String) {
    self.summarize = summarize
  }
}
