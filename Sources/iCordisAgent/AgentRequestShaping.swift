import Foundation
import iCordisKernel

/// The kind of model turn being shaped. Stamped into `william.request.kind`,
/// which the hosted backend reads to decide whether to send the full agent
/// trajectory (agent turns) or collapse to "system + latest user" (chat).
public enum AgentRequestKind: String, Sendable {
  case agentTurn = "agent"
  case chat = "chat"
  case taskIntent = "agent_task_intent"
  case completionJudge = "agent_completion_judge"
  case runStop = "agent_run_stop"
  case contextCompress = "agent_context_compress"
}

/// A neutral description of one model turn, before it is shaped into an
/// `AIRequest`. Every caller (the in-process loop, the DSH bridge) builds one of
/// these and runs it through the single `AgentRequestShaper` seam, so request
/// shaping cannot drift between paths — the class of bug where one path stamped
/// `william.request.kind` and the other did not.
public struct AgentModelRequestDraft: Sendable {
  public var sessionID: UUID
  public var modelID: UUID
  public var kind: AgentRequestKind
  public var messages: [ConversationItem]
  public var capabilities: [CapabilityDescriptor]
  public var parameters: InferenceParameters
  public var structuredOutputSchema: JSONValue?
  public var protocolMetadata: [String: JSONValue]

  public init(
    sessionID: UUID,
    modelID: UUID,
    kind: AgentRequestKind,
    messages: [ConversationItem],
    capabilities: [CapabilityDescriptor] = [],
    parameters: InferenceParameters = .default,
    structuredOutputSchema: JSONValue? = nil,
    protocolMetadata: [String: JSONValue] = [:]
  ) {
    self.sessionID = sessionID
    self.modelID = modelID
    self.kind = kind
    self.messages = messages
    self.capabilities = capabilities
    self.parameters = parameters
    self.structuredOutputSchema = structuredOutputSchema
    self.protocolMetadata = protocolMetadata
  }
}

/// The canonical terminal of the request-shaping waterfall: turns a draft into
/// the `AIRequest` every backend sees. This is the single source of truth for
/// request shaping (kind stamping, agent-turn parameter policy).
public enum AgentTurnRequestBuilder {
  public static func build(_ draft: AgentModelRequestDraft) -> AIRequest {
    var parameters = draft.parameters
    if draft.kind == .agentTurn {
      // Agent turns stream, run cool, and reserve the full output budget.
      parameters.stream = true
      parameters.temperature = min(parameters.temperature, 0.3)
      parameters.maxTokens = AgentLLMClient.outputTokenLimit
    }
    var metadata = draft.protocolMetadata
    metadata["william.request.kind"] = .string(draft.kind.rawValue)
    return AIRequest(
      sessionID: draft.sessionID,
      modelID: draft.modelID,
      outputPreference: .responses,
      messages: draft.messages,
      parameters: parameters,
      capabilityDescriptors: draft.capabilities,
      structuredOutputSchema: draft.structuredOutputSchema,
      protocolMetadata: metadata
    )
  }
}

/// The single request-shaping seam, provided as a service so every caller shares
/// it. It builds the canonical request, then runs it through the Cordis-style
/// `model/request` waterfall (`RuntimeEvents.modelRequest`) so plugins can
/// transform it — the same primitive the architecture doc promises.
public struct AgentRequestShaper: WilliamService {
  public let shape: @Sendable (AgentModelRequestDraft) async throws -> AIRequest

  /// A shaper with no plugin middlewares — just the canonical builder. Used as
  /// the fallback when the service is not mounted, so callers always have the
  /// same base shaping even without the plugin.
  public static let passthrough = AgentRequestShaper { AgentTurnRequestBuilder.build($0) }

  public init(shape: @escaping @Sendable (AgentModelRequestDraft) async throws -> AIRequest) {
    self.shape = shape
  }
}
