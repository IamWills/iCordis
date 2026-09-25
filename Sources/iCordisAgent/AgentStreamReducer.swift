import Foundation
import iCordisKernel

public struct AgentStreamReducer: Sendable {
  private let chunkSize: Int

  public init(chunkSize: Int = 16) {
    self.chunkSize = max(1, chunkSize)
  }

  public func streamText(_ text: String, messageID: UUID) -> [StreamEvent] {
    guard !text.isEmpty else { return [] }
    return chunks(from: text).map {
      .textDelta(messageID: messageID, delta: $0)
    }
  }

  private func chunks(from text: String) -> [String] {
    var output: [String] = []
    var index = text.startIndex
    while index < text.endIndex {
      let end = text.index(index, offsetBy: chunkSize, limitedBy: text.endIndex) ?? text.endIndex
      output.append(String(text[index..<end]))
      index = end
    }
    return output
  }
}
