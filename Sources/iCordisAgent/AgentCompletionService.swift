import Foundation
import iCordisKernel

/// Shared by both runtime drivers. Resolved at each review so replacements take effect live.
public struct AgentCompletionService: WilliamService {
  public let review: @Sendable (AIRequest) async throws -> AgentCompletionDecision

  public static func modelProvider(_ model: ModelService) -> Self {
    Self { request in
      let stream = try await model.generate(request)
      var reducer = NativeAgentStreamReducer()
      var output = ""
      for try await event in stream {
        try Task.checkCancellation()
        switch event {
        case .responseEvent(let event):
          if let failure = ResponsesTextStreamReducer.failureMessage(from: event) {
            throw InferenceError.runtimeFailure(failure)
          }
          output += reducer.consume(event).map(\.text).joined()
        case .textDelta(_, let text): output += text
        case .failed(_, let message): throw InferenceError.runtimeFailure(message)
        default: break
        }
      }
      return try AgentCompletionDecisionParser().parse(output)
    }
  }

  public init(review: @escaping @Sendable (AIRequest) async throws -> AgentCompletionDecision) {
    self.review = review
  }
}

public struct AgentCompletionPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.agent-completion"), name: "LLM Completion Review",
    version: SemanticVersion(1), capabilities: [PluginCapability("agent.completion")],
    requiredServices: [RuntimeServices.model.id],
    providedServices: [RuntimeServices.agentCompletion.id, RuntimeServices.agentProgress.id]
  )
  public func apply(to context: PluginContext) async throws {
    try await context.provide(AgentProgressService.standard, as: RuntimeServices.agentProgress)
    let model = try await context.service(RuntimeServices.model)
    try await context.provide(
      AgentCompletionService.modelProvider(model), as: RuntimeServices.agentCompletion)
  }

  public init() {}
}
