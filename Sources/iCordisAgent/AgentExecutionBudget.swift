import Foundation
import iCordisKernel

/// A replaceable policy for admitting model turns and tool executions.
/// Each Agent run receives its own counter; plugin replacement affects new runs.
public struct AgentExecutionBudgetService: WilliamService {
  public let makeRun: @Sendable (_ runID: UUID) async -> AgentExecutionBudgetRun

  public init(makeRun: @escaping @Sendable (UUID) async -> AgentExecutionBudgetRun) {
    self.makeRun = makeRun
  }
}

public enum AgentExecutionBudgetError: Error, LocalizedError, Sendable, Equatable {
  case modelTurnsExhausted(limit: Int)
  case toolCallsExhausted(limit: Int)

  public var errorDescription: String? {
    switch self {
    case .modelTurnsExhausted(let limit):
      return "Agent run reached its model-turn limit (\(limit))."
    case .toolCallsExhausted(let limit):
      return "Agent run reached its tool-call limit (\(limit))."
    }
  }
}

/// Run-local admission gate. Calls are serialized by the actor so concurrent
/// tool requests cannot collectively exceed the configured limit.
public actor AgentExecutionBudgetRun {
  private let maxModelTurns: Int?
  private let maxToolCalls: Int?
  private var modelTurns = 0
  private var toolCalls = 0

  public init(maxModelTurns: Int? = nil, maxToolCalls: Int? = nil) {
    self.maxModelTurns = maxModelTurns.map { max(0, $0) }
    self.maxToolCalls = maxToolCalls.map { max(0, $0) }
  }

  public func admitModelTurn() throws {
    if let limit = maxModelTurns, modelTurns >= limit {
      throw AgentExecutionBudgetError.modelTurnsExhausted(limit: limit)
    }
    modelTurns += 1
  }

  public func admitToolCall() throws {
    if let limit = maxToolCalls, toolCalls >= limit {
      throw AgentExecutionBudgetError.toolCallsExhausted(limit: limit)
    }
    toolCalls += 1
  }

  public func snapshot() -> (modelTurns: Int, toolCalls: Int) {
    (modelTurns, toolCalls)
  }
}

/// Optional policy plugin. No budget is imposed unless a host mounts it.
/// Another plugin may replace the same service slot without changing AgentLoop.
public struct AgentExecutionBudgetPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.agent.execution-budget"),
    name: "Agent Execution Budget",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent.execution-budget")],
    providedServices: [RuntimeServices.executionBudget.id]
  )

  public let maxModelTurns: Int?
  public let maxToolCalls: Int?

  public init(maxModelTurns: Int? = nil, maxToolCalls: Int? = nil) {
    self.maxModelTurns = maxModelTurns
    self.maxToolCalls = maxToolCalls
  }

  public func apply(to context: PluginContext) async throws {
    let turns = maxModelTurns
    let tools = maxToolCalls
    try await context.provide(
      AgentExecutionBudgetService(makeRun: { _ in
        AgentExecutionBudgetRun(maxModelTurns: turns, maxToolCalls: tools)
      }),
      as: RuntimeServices.executionBudget
    )
  }
}
