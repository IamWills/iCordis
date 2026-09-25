import Foundation
import iCordisKernel

public enum StreamEventMapper {
  public static func collectText(from events: [StreamEvent]) -> String {
    events.reduce(into: "") { partial, event in
      if case .textDelta(_, let delta) = event {
        partial.append(delta)
      }
    }
  }

  public static func collectReasoning(from events: [StreamEvent]) -> String {
    events.reduce(into: "") { partial, event in
      if case .reasoningDelta(_, let delta) = event {
        partial.append(delta)
      }
    }
  }

  public static func responseEvents(from event: StreamEvent, responseID fallbackResponseID: UUID)
    -> [ResponseStreamEvent]
  {
    switch event {
    case .responseEvent(let responseEvent):
      return [responseEvent]
    case .started(let responseID, _):
      return [
        .responseCreated(responseID: responseID)
      ]
    case .textDelta(let messageID, let delta):
      return [
        .outputTextDelta(responseID: fallbackResponseID, messageID: messageID, delta: delta)
      ]
    case .reasoningDelta(let messageID, let delta):
      return [
        .reasoningTextDelta(responseID: fallbackResponseID, messageID: messageID, delta: delta)
      ]
    case .capabilityInvocationStarted:
      return []
    case .capabilityInvocation(let trace):
      return ResponseStreamEvent.functionCallOutput(responseID: fallbackResponseID, trace: trace)
    case .usage(let usage):
      return [
        .responseCompleted(responseID: fallbackResponseID, usage: usage)
      ]
    case .completed(_, _):
      return [
        .responseCompleted(responseID: fallbackResponseID)
      ]
    case .failed(let messageID, let description):
      return [
        .responseFailed(
          responseID: fallbackResponseID, messageID: messageID, description: description)
      ]
    }
  }
}

public enum UsageMapper {
  public static func dictionary(from usage: Usage) -> [String: JSONValue] {
    [
      "input_tokens": .number(Double(usage.inputTokens)),
      "output_tokens": .number(Double(usage.outputTokens)),
      "total_tokens": .number(Double(usage.totalTokens)),
      "input_tokens_details": .object([
        "cached_tokens": .number(0)
      ]),
      "output_tokens_details": .object([
        "reasoning_tokens": .number(0)
      ]),
      "tokens_per_second": usage.tokensPerSecond.map(JSONValue.number) ?? .null,
    ]
  }
}

public enum CapabilityInvocationMapper {
  public static func outputItem(from trace: CapabilityExecutionTrace) -> OutputItem {
    OutputItem(
      kind: .toolResult,
      role: .tool,
      content: trace.result.content,
      name: trace.request.capabilityID,
      payload: trace.result.rawPayload
    )
  }
}

public enum UnifiedConversationMapper {
  public static func response(session: ConversationSession, usage: Usage = .zero) -> AIResponse {
    let output =
      session.items.map {
        OutputItem(
          kind: .message, role: $0.role, content: $0.content, payload: .object($0.protocolMetadata))
      } + session.traces.map(CapabilityInvocationMapper.outputItem)
    return AIResponse(
      id: UUID(),
      sessionID: session.id,
      modelID: session.selectedModelID ?? UUID(),
      output: output,
      usage: usage,
      createdAt: .now,
      metadata: [:]
    )
  }
}
