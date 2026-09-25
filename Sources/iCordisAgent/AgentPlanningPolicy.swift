import Foundation
import iCordisKernel

public struct AgentPlanningPolicy: Sendable {
  public let configuration: AgentConfiguration

  public func shouldContinue(iteration: Int, toolCalls: Int) throws {
    if iteration >= configuration.maxIterations {
      throw AgentError.maxIterationsExceeded
    }
    if toolCalls >= configuration.maxToolCalls {
      throw AgentError.maxToolCallsExceeded
    }
  }

  public init(configuration: AgentConfiguration) { self.configuration = configuration }
}
