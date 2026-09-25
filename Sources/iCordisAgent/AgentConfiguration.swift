import Foundation
import iCordisKernel

public struct AgentConfiguration: Codable, Hashable, Sendable {
  public var maxIterations: Int
  public var maxToolCalls: Int
  public var toolTimeout: TimeInterval
  public var maxObservationCharacters: Int
  public var maxScratchpadCharacters: Int
  public var actionRepairAttempts: Int
  /// Character budget for prior conversation turns in the Agent prompt prefix.
  public var maxPromptHistoryCharacters: Int
  /// Soft cap on prior conversation turns kept before older ones are compressed.
  public var maxPromptHistoryMessages: Int

  public init(
    maxIterations: Int,
    maxToolCalls: Int,
    toolTimeout: TimeInterval,
    maxObservationCharacters: Int,
    maxScratchpadCharacters: Int,
    actionRepairAttempts: Int,
    maxPromptHistoryCharacters: Int = 80_000,
    maxPromptHistoryMessages: Int = 40
  ) {
    self.maxIterations = maxIterations
    self.maxToolCalls = maxToolCalls
    self.toolTimeout = toolTimeout
    self.maxObservationCharacters = maxObservationCharacters
    self.maxScratchpadCharacters = maxScratchpadCharacters
    self.actionRepairAttempts = actionRepairAttempts
    self.maxPromptHistoryCharacters = maxPromptHistoryCharacters
    self.maxPromptHistoryMessages = maxPromptHistoryMessages
  }

  public static let production = AgentConfiguration(
    maxIterations: 16,
    maxToolCalls: 32,
    toolTimeout: 30,
    maxObservationCharacters: 32_000,
    maxScratchpadCharacters: 280_000,
    actionRepairAttempts: 2
  )
}
