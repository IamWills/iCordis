import Foundation
import iCordisKernel

public struct AgentTraceStore: Sendable {
  public func makeSummaryTrace(from summary: AgentRunSummary) -> CapabilityExecutionTrace {
    let result = CapabilityInvocationResult(
      capabilityID: "agent.run",
      success: summary.completionStatus == .completed,
      content: [
        .text(
          "Agent finished \(summary.steps.count) step(s) with status \(summary.completionStatus.rawValue)."
        )
      ],
      rawPayload: summaryPayload(summary),
      latency: summary.finishedAt.timeIntervalSince(summary.startedAt)
    )
    return CapabilityExecutionTrace(
      id: summary.id,
      request: CapabilityInvocationRequest(
        sessionID: summary.sessionID,
        capabilityID: "agent.run",
        arguments: ["task": .string(summary.task)],
        initiatedBy: .assistant,
        timeout: nil
      ),
      result: result,
      startedAt: summary.startedAt,
      finishedAt: summary.finishedAt
    )
  }

  private func summaryPayload(_ summary: AgentRunSummary) -> JSONValue {
    .object([
      "id": .string(summary.id.uuidString),
      "task": .string(summary.task),
      "finalAnswer": summary.finalAnswer.map(JSONValue.string) ?? .null,
      "completionStatus": .string(summary.completionStatus.rawValue),
      "activeInstructionSkillIDs": .array(summary.activeInstructionSkillIDs.map(JSONValue.string)),
      "unmetRequirements": .array(summary.unmetRequirements.map(JSONValue.string)),
      "startedAt": .string(ISO8601DateFormatter().string(from: summary.startedAt)),
      "finishedAt": .string(ISO8601DateFormatter().string(from: summary.finishedAt)),
      "steps": .array(summary.steps.map(stepPayload)),
    ])
  }

  private func stepPayload(_ step: AgentStep) -> JSONValue {
    var object: [String: JSONValue] = [
      "id": .string(step.id.uuidString),
      "index": .number(Double(step.index)),
      "outcome": .string(step.outcome.rawValue),
      "modelOutput": .string(step.modelOutput),
      "startedAt": .string(ISO8601DateFormatter().string(from: step.startedAt)),
    ]
    if let finishedAt = step.finishedAt {
      object["finishedAt"] = .string(ISO8601DateFormatter().string(from: finishedAt))
    }
    if let observation = step.observation {
      object["observation"] = .string(observation)
    }
    if let toolCall = step.toolCall {
      object["toolCall"] = .object([
        "capabilityID": .string(toolCall.capabilityID),
        "arguments": .object(toolCall.arguments),
        "rationale": toolCall.rationale.map(JSONValue.string) ?? .null,
      ])
    }
    return .object(object)
  }

  public init() {}
}
