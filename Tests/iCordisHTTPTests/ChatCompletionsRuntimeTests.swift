import Foundation
import Testing
import iCordisHTTP

@Suite struct ChatCompletionsRuntimeTests {
    // MARK: - Message conversion

    @Test func plainTextItemsBecomeRoleMessages() {
        let items = [
            ConversationItem(role: .system, content: [.text("be brief")]),
            ConversationItem(role: .user, content: [.text("hi")])
        ]
        let messages = ChatCompletionsRuntime.chatMessages(from: items)
        #expect(messages.count == 2)
        #expect(messages[0].pluginObjectValue?["role"]?.stringValue == "system")
        #expect(messages[0].pluginObjectValue?["content"]?.stringValue == "be brief")
        #expect(messages[1].pluginObjectValue?["role"]?.stringValue == "user")
        #expect(messages[1].pluginObjectValue?["content"]?.stringValue == "hi")
    }

    @Test func toolCallItemBecomesAssistantToolCalls() throws {
        let call = ToolCallContentPart.FunctionCall(callID: "call_1", name: "william_fs_read", arguments: "{\"path\":\"a\"}")
        let item = ConversationItem(role: .assistant, content: [ToolCallContentPart.part(for: call)])
        let messages = ChatCompletionsRuntime.chatMessages(from: [item])
        let assistant = try #require(messages.first?.pluginObjectValue)
        #expect(assistant["role"]?.stringValue == "assistant")
        let toolCalls = try #require(assistant["tool_calls"]?.pluginArrayValue)
        #expect(toolCalls.count == 1)
        let function = toolCalls[0].pluginObjectValue?["function"]?.pluginObjectValue
        #expect(toolCalls[0].pluginObjectValue?["id"]?.stringValue == "call_1")
        #expect(function?["name"]?.stringValue == "william_fs_read")
        #expect(function?["arguments"]?.stringValue == "{\"path\":\"a\"}")
    }

    @Test func toolResultItemBecomesToolRoleMessage() throws {
        let output = ToolCallContentPart.FunctionCallOutput(callID: "call_1", output: "file contents")
        let item = ConversationItem(role: .tool, content: [ToolCallContentPart.part(for: output)])
        let messages = ChatCompletionsRuntime.chatMessages(from: [item])
        let tool = try #require(messages.first?.pluginObjectValue)
        #expect(tool["role"]?.stringValue == "tool")
        #expect(tool["tool_call_id"]?.stringValue == "call_1")
        #expect(tool["content"]?.stringValue == "file contents")
    }

    // MARK: - Tool declaration

    @Test func toolsUseSanitizedNamesAndSchema() throws {
        let descriptor = CapabilityDescriptor(
            id: "william.fs.read",
            kind: .pluginTool,
            name: "Read File",
            summary: "Reads a file",
            schema: CapabilityParameterSchema(
                type: "object",
                properties: ["path": .object(["type": .string("string")])],
                required: ["path"]
            ),
            isEnabled: true,
            metadata: [:]
        )
        let tools = ChatCompletionsRuntime.tools(from: [descriptor])
        let function = try #require(tools.first?.pluginObjectValue?["function"]?.pluginObjectValue)
        #expect(function["name"]?.stringValue == ToolFunctionName.sanitized("william.fs.read"))
        #expect(function["description"]?.stringValue == "Reads a file")
        let parameters = function["parameters"]?.pluginObjectValue
        #expect(parameters?["type"]?.stringValue == "object")
        #expect(parameters?["required"]?.pluginArrayValue?.first?.stringValue == "path")
    }

    @Test func disabledToolsAreExcluded() {
        let descriptor = CapabilityDescriptor(
            id: "x", kind: .pluginTool, name: "X", summary: "",
            schema: CapabilityParameterSchema(type: "object", properties: [:], required: []),
            isEnabled: false, metadata: [:]
        )
        #expect(ChatCompletionsRuntime.tools(from: [descriptor]).isEmpty)
    }

    @Test func requestBodyIsStreaming() {
        let request = AIRequest(
            sessionID: UUID(), modelID: UUID(), outputPreference: .responses,
            messages: [ConversationItem(role: .user, content: [.text("hi")])],
            parameters: .default, capabilityDescriptors: []
        )
        let body = ChatCompletionsRuntime.requestBody(request: request, configuration: chatConfig())
        #expect(body.pluginObjectValue?["stream"]?.pluginBoolValue == true)
    }

    // MARK: - SSE parsing

    @Test func parseSSELineClassifies() {
        if case .chunk(let json) = ChatCompletionsRuntime.parseSSELine("data: {\"a\":1}") {
            #expect(json.pluginObjectValue?["a"]?.pluginNumberValue == 1)
        } else {
            Issue.record("expected a chunk")
        }
        if case .done = ChatCompletionsRuntime.parseSSELine("data: [DONE]") {} else {
            Issue.record("expected done")
        }
        if case .ignore = ChatCompletionsRuntime.parseSSELine(": keep-alive") {} else {
            Issue.record("expected ignore for comment")
        }
        if case .ignore = ChatCompletionsRuntime.parseSSELine("") {} else {
            Issue.record("expected ignore for blank")
        }
    }

    // MARK: - Streaming accumulation

    @Test func textDeltasStreamThenComplete() {
        var acc = ChatCompletionsStreamAccumulator(responseID: UUID())
        _ = acc.start()
        let first = acc.consume(textChunk("Hello"))
        let second = acc.consume(textChunk(" world"))
        let done = acc.finish()

        // First content delta opens the message item, then streams the delta.
        #expect(first.contains { $0.type == "response.output_item.added" })
        #expect(first.first { $0.type == "response.output_text.delta" }?.delta == "Hello")
        #expect(second.first { $0.type == "response.output_text.delta" }?.delta == " world")
        #expect(done.contains { $0.type == "response.output_text.done" })
        #expect(done.last?.type == "response.completed")
    }

    @Test func toolCallFragmentsAccumulateAcrossChunks() throws {
        var acc = ChatCompletionsStreamAccumulator(responseID: UUID())
        _ = acc.start()
        _ = acc.consume(toolChunk(index: 0, id: "call_1", name: "william_fs_read", arguments: "{\"pa"))
        _ = acc.consume(toolChunk(index: 0, id: nil, name: nil, arguments: "th\":\"x\"}"))
        let done = acc.finish()

        let added = try #require(done.first { $0.type == "response.output_item.added" })
        #expect(added.item?.type == "function_call")
        #expect(added.item?.name == "william_fs_read")
        #expect(added.item?.callID == "call_1")
        #expect(added.item?.arguments == "{\"path\":\"x\"}")
        #expect(done.last?.type == "response.completed")
    }

    @Test func usageFromFinalChunkIsCarried() throws {
        var acc = ChatCompletionsStreamAccumulator(responseID: UUID())
        _ = acc.start()
        _ = acc.consume(textChunk("ok"))
        _ = acc.consume(.object([
            "choices": .array([]),
            "usage": .object([
                "prompt_tokens": .number(10), "completion_tokens": .number(2), "total_tokens": .number(12)
            ])
        ]))
        let done = acc.finish()
        let completed = try #require(done.first { $0.type == "response.completed" })
        #expect(completed.response?.usage != nil)
    }

    // MARK: - Helpers

    private func textChunk(_ content: String) -> JSONValue {
        .object(["choices": .array([.object(["delta": .object(["content": .string(content)])])])])
    }

    private func toolChunk(index: Int, id: String?, name: String?, arguments: String) -> JSONValue {
        var function: [String: JSONValue] = ["arguments": .string(arguments)]
        if let name { function["name"] = .string(name) }
        var call: [String: JSONValue] = ["index": .number(Double(index)), "function": .object(function)]
        if let id { call["id"] = .string(id) }
        return .object(["choices": .array([.object(["delta": .object(["tool_calls": .array([.object(call)])])])])])
    }

    private func chatConfig() -> HostedResponsesAPISettings {
        HostedResponsesAPISettings(
            id: UUID(), apiProtocol: .openAIChatCompletions,
            baseURL: "https://api.deepseek.com/v1", model: "deepseek-chat",
            apiKey: "k", providerLabel: "DeepSeek"
        )
    }
}
