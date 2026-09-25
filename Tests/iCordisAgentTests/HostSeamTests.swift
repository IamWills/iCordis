import Foundation
import Testing
import iCordisAgent

@Test func neutralCopyDoesNotNameWilliam() {
  let failure = AgentCopyService.neutral.render(
    .providerFailure(detail: "timeout", completedTools: ["fs.read"])
  )
  #expect(failure.contains("William") == false)
  #expect(failure.contains("timeout"))
  #expect(failure.contains("fs.read"))
  let stopped = AgentCopyService.neutral.render(.outputLimitStopped)
  #expect(stopped.contains("William") == false)
}

@Test func williamCopyPluginRestoresProductVoice() {
  let failure = AgentCopyService.william.render(
    .providerFailure(detail: "timeout", completedTools: [])
  )
  #expect(failure.contains("William"))
  #expect(WilliamTranscriptCopyPlugin.manifest.providedServices.contains(
    RuntimeServices.transcriptCopy.id))
}

@Test func reasoningPresentationDefaultsToTypedEvent() {
  #expect(ReasoningPresentation.typedEvent.style == .typedEvent)
  if case .transcriptMarkers(let open, let close) = ReasoningPresentation.williamTranscript.style {
    #expect(open.contains("<reasoning"))
    #expect(close.contains("</reasoning>"))
  } else {
    Issue.record("expected transcript markers")
  }
}

@Test func streamEventKeepsReasoningOffTheAnswerChannel() {
  let messageID = UUID()
  let events: [StreamEvent] = [
    .reasoningDelta(messageID: messageID, delta: "plan"),
    .textDelta(messageID: messageID, delta: "answer"),
  ]
  #expect(StreamEventMapper.collectReasoning(from: events) == "plan")
  #expect(StreamEventMapper.collectText(from: events) == "answer")
  let mapped = StreamEventMapper.responseEvents(from: events[0], responseID: UUID())
  #expect(mapped.first?.type == "response.reasoning_text.delta")
  #expect(mapped.first?.delta == "plan")
}

@Test func toolCallAssemblerJoinsFragmentsAndDecodesArguments() {
  var assembler = StreamingToolCallAssembler<Int>()
  assembler.appendArguments("{\"pa", key: 0, fallbackCallID: "call_0")
  assembler.register(key: 0, name: "fs.read", callID: "call_1")
  assembler.appendArguments("th\":\"a\"}", key: 0, fallbackCallID: "call_0")
  assembler.complete(arguments: "{\"path\":\"a\"}", key: 0)
  let ordered = assembler.ordered()
  #expect(ordered.count == 1)
  #expect(ordered[0].fragment.name == "fs.read")
  #expect(ordered[0].fragment.callID == "call_1")
  #expect(ordered[0].fragment.isComplete)
  #expect(
    StreamingToolCallAssembler<Int>.decodeArguments(ordered[0].fragment.arguments)["path"]
      == .string("a"))
}
