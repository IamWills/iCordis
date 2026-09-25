# Changelog

## 0.1.3

- Add `StreamEvent.reasoningDelta` so chain-of-thought is a stream branch. The default presentation does not write it into the answer channel; mount `WilliamReasoningTranscriptPlugin` to keep `<reasoning>` transcript markers.
- Let hosts replace transcript sentences through `AgentCopyService`. The loop default is product-neutral. Mount `WilliamTranscriptCopyPlugin` for the previous William voice.
- Share tool-call fragment assembly through `StreamingToolCallAssembler`, used by `NativeAgentStreamReducer` and `ChatCompletionsStreamAccumulator`. Chat Completions forwards `reasoning_content` and `reasoning` as `response.reasoning_text.delta`.

## 0.1.2

- Simplify action-parser type inference for Swift 6.0/6.1.

## 0.1.1

- Fix Task references for Swift 6.0/6.1 toolchains used by GitHub CI.

## 0.1.0

- Extract the Swift plugin kernel and actual default Agent runtime from William.
- Publish independent iCordisKernel, iCordisAgent, and optional iCordisHTTP products.
- Preserve plugin-driven models, tools, sessions, memory, context, policies and completion review.
- Replace concrete host dependencies with protocols and service adapters.
- Add public APIs, packaged prompts, an offline/live CLI example, and MIT licensing.
- Add standalone tests and macOS/iOS Simulator CI.
