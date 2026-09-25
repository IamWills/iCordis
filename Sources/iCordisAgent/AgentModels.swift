import Foundation
import iCordisKernel

public enum AgentAction: Hashable, Sendable {
  case toolCall(AgentToolCall)
  case finalAnswer(String)
}

public struct AgentToolCall: Codable, Hashable, Sendable {
  public var capabilityID: String
  public var arguments: [String: JSONValue]
  public var rationale: String?

  public init(capabilityID: String, arguments: [String: JSONValue], rationale: String? = nil) {
    self.capabilityID = capabilityID
    self.arguments = arguments
    self.rationale = rationale
  }
}

public struct AgentStep: Codable, Hashable, Identifiable, Sendable {
  public enum Outcome: String, Codable, Sendable {
    case toolCall
    case finalAnswer
    case parserRepair
    case failed
    /// A runtime fact injected into the trajectory (budget notice, unmet
    /// completion requirement) rather than a model or tool action.
    case runtimeNote
  }

  public var id: UUID
  public var index: Int
  public var outcome: Outcome
  public var modelOutput: String
  public var toolCall: AgentToolCall?
  public var observation: String?
  public var startedAt: Date
  public var finishedAt: Date?

  public init(
    id: UUID = UUID(),
    index: Int,
    outcome: Outcome,
    modelOutput: String,
    toolCall: AgentToolCall? = nil,
    observation: String? = nil,
    startedAt: Date = .now,
    finishedAt: Date? = nil
  ) {
    self.id = id
    self.index = index
    self.outcome = outcome
    self.modelOutput = modelOutput
    self.toolCall = toolCall
    self.observation = observation
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}

public struct AgentRunSummary: Codable, Hashable, Sendable {
  public var id: UUID
  public var sessionID: UUID
  public var task: String
  public var steps: [AgentStep]
  public var finalAnswer: String?
  public var completionStatus: AgentRunCompletionStatus
  public var activeInstructionSkillIDs: [String]
  public var unmetRequirements: [String]
  public var startedAt: Date
  public var finishedAt: Date

  public init(
    id: UUID = UUID(),
    sessionID: UUID,
    task: String,
    steps: [AgentStep],
    finalAnswer: String?,
    completionStatus: AgentRunCompletionStatus = .completed,
    activeInstructionSkillIDs: [String] = [],
    unmetRequirements: [String] = [],
    startedAt: Date,
    finishedAt: Date = .now
  ) {
    self.id = id
    self.sessionID = sessionID
    self.task = task
    self.steps = steps
    self.finalAnswer = finalAnswer
    self.completionStatus = completionStatus
    self.activeInstructionSkillIDs = activeInstructionSkillIDs
    self.unmetRequirements = unmetRequirements
    self.startedAt = startedAt
    self.finishedAt = finishedAt
  }
}
