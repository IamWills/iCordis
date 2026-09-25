import Foundation
import iCordisKernel

public enum AgentExecutionEvent: Sendable, Hashable {
  case started(runID: UUID)
  case stepCompleted(AgentStep)
  case capabilityInvocationStarted(CapabilityInvocationProgress)
  case capabilityInvocation(CapabilityExecutionTrace)
  case textDelta(messageID: UUID, delta: String)
  case completed(messageID: UUID, summary: AgentRunSummary)
}
