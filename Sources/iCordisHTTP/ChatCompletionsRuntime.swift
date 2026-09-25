import Foundation
@_exported import iCordisAgent

/// Route-B model backend: adapts a standard OpenAI-compatible `/chat/completions`
/// endpoint (OpenAI, DeepSeek, …) up to William's internal Responses `StreamEvent`
/// contract. It is a sibling of `HostedResponsesRuntime` behind
/// `UnifiedInferenceRuntime`, selected when a configured hosted model carries the
/// `hosted.protocol = openai-chat-completions` tag.
///
/// Output is **streaming by default** (SSE): text is emitted delta-by-delta as it
/// arrives, and tool-call fragments are accumulated across chunks and surfaced as
/// `function_call` output items the agent's reducer runs.
///
/// Context is local-authoritative: the request already carries the assembled
/// `messages` (William owns the conversation), and `CanonicalResponsesRuntime`
/// persists the emitted events and mints/binds the conversation id — so this
/// runtime holds no state beyond the active model and in-flight tasks.
public actor ChatCompletionsRuntime: InferenceRuntimeProtocol {
    private let settings: @Sendable () async throws -> AppSettings
    private let session: URLSession
    private var activeModel: LocalModelDescriptor?
    private var tasks: [UUID: Task<Void, Never>] = [:]

    public init(settings: @escaping @Sendable () async throws -> AppSettings, session: URLSession = .shared) {
        self.settings = settings
        self.session = session
    }

    public func activeModelID() async -> UUID? { activeModel?.id }
    public func loadModel(_ model: LocalModelDescriptor) async throws { activeModel = model }
    public func unloadModel() async { activeModel = nil }

    public func cancelGeneration(sessionID: UUID) async {
        tasks.removeValue(forKey: sessionID)?.cancel()
    }

    public func generate(request: AIRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
        guard let model = activeModel, model.id == request.modelID else {
            throw InferenceError.runtimeUnavailable
        }
        let settings = try await settings()
        guard let configuration = HostedResponsesModel.configuration(from: settings, matching: model),
              configuration.isConfigured else {
            throw InferenceError.runtimeUnavailable
        }

        let (stream, continuation) = AsyncThrowingStream<StreamEvent, Error>.makeStream(
            bufferingPolicy: .unbounded
        )
        let sessionID = request.sessionID
        let task = Task {
            await self.run(request: request, configuration: configuration, continuation: continuation)
            await self.clearTask(sessionID: sessionID)
        }
        tasks[sessionID] = task
        continuation.onTermination = { [weak self] termination in
            if case .cancelled = termination {
                Task { await self?.cancelGeneration(sessionID: sessionID) }
            }
        }
        return stream
    }

    private func clearTask(sessionID: UUID) {
        tasks[sessionID] = nil
    }

    // MARK: - One streamed request

    private func run(
        request: AIRequest,
        configuration: HostedResponsesAPISettings,
        continuation: AsyncThrowingStream<StreamEvent, Error>.Continuation
    ) async {
        let responseID = UUID()
        var accumulator = ChatCompletionsStreamAccumulator(responseID: responseID)
        func emit(_ events: [ResponseStreamEvent]) {
            for event in events { continuation.yield(.responseEvent(event)) }
        }
        do {
            let body = Self.requestBody(request: request, configuration: configuration)
            let urlRequest = try Self.urlRequest(configuration: configuration, body: body)
            let (bytes, response) = try await session.bytes(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ChatCompletionsError.transport("no HTTP response")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw ChatCompletionsError.http(http.statusCode, try await Self.collectError(from: bytes))
            }

            emit(accumulator.start())
            for try await line in bytes.lines {
                try Task.checkCancellation()
                switch Self.parseSSELine(line) {
                case .done:
                    emit(accumulator.finish())
                    continuation.finish()
                    return
                case .chunk(let json):
                    emit(accumulator.consume(json))
                case .ignore:
                    continue
                }
            }
            // Stream ended without an explicit [DONE].
            emit(accumulator.finish())
            continuation.finish()
        } catch is CancellationError {
            continuation.finish()
        } catch {
            continuation.yield(.responseEvent(.responseFailed(
                responseID: responseID,
                messageID: nil,
                description: UserFacingErrorMapper.message(for: error)
            )))
            continuation.finish()
        }
    }

    /// Reads a bounded amount of an error response body for diagnostics.
    private static func collectError(from bytes: URLSession.AsyncBytes) async throws -> String {
        var collected = ""
        for try await line in bytes.lines {
            collected += line
            if collected.count > 400 { break }
        }
        return String(collected.prefix(400))
    }

    /// Splits one SSE line into a decoded data chunk, the terminal marker, or a
    /// line to skip (comments, blank lines, non-`data:` fields).
    public static func parseSSELine(_ line: String) -> SSELine {
        guard line.hasPrefix("data:") else { return .ignore }
        let payload = line.dropFirst("data:".count).trimmingCharacters(in: .whitespaces)
        if payload == "[DONE]" { return .done }
        guard let data = payload.data(using: .utf8),
              let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            return .ignore
        }
        return .chunk(json)
    }

    public enum SSELine: Sendable {
        case chunk(JSONValue)
        case done
        case ignore
    }

    // MARK: - Request building

    private static func urlRequest(configuration: HostedResponsesAPISettings, body: JSONValue) throws -> URLRequest {
        let base = configuration.normalizedBaseURL.hasSuffix("/")
            ? String(configuration.normalizedBaseURL.dropLast())
            : configuration.normalizedBaseURL
        guard let url = URL(string: "\(base)/chat/completions") else {
            throw ChatCompletionsError.transport("invalid base URL")
        }
        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        if !configuration.normalizedAPIKey.isEmpty {
            urlRequest.setValue("Bearer \(configuration.normalizedAPIKey)", forHTTPHeaderField: "Authorization")
        }
        urlRequest.httpBody = try JSONEncoder().encode(body)
        return urlRequest
    }

    public static func requestBody(request: AIRequest, configuration: HostedResponsesAPISettings) -> JSONValue {
        let modelName = configuration.normalizedModel.isEmpty
            ? configuration.resolvedModelName
            : configuration.normalizedModel
        var payload: [String: JSONValue] = [
            "model": .string(modelName),
            "messages": .array(chatMessages(from: request.messages)),
            "stream": .bool(true),
            // Ask compatible gateways to include token usage in the final chunk.
            "stream_options": .object(["include_usage": .bool(true)])
        ]
        let tools = self.tools(from: request.capabilityDescriptors)
        if !tools.isEmpty {
            payload["tools"] = .array(tools)
            payload["tool_choice"] = .string("auto")
        }
        return .object(payload)
    }

    /// ConversationItem[] → OpenAI chat messages, preserving tool-call turns.
    public static func chatMessages(from items: [ConversationItem]) -> [JSONValue] {
        var messages: [JSONValue] = []
        for item in items {
            let text = item.content
                .filter { $0.kind == .text || $0.kind == .code }
                .compactMap(\.text)
                .joined(separator: "\n")
            let calls = item.content.compactMap(ToolCallContentPart.functionCall(from:))
            let outputs = item.content.compactMap(ToolCallContentPart.functionCallOutput(from:))

            // A tool result item becomes one `tool` message per output.
            for output in outputs {
                messages.append(.object([
                    "role": .string("tool"),
                    "tool_call_id": .string(output.callID),
                    "content": .string(output.output)
                ]))
            }
            if !calls.isEmpty {
                messages.append(.object([
                    "role": .string("assistant"),
                    "content": text.isEmpty ? .null : .string(text),
                    "tool_calls": .array(calls.map { call in
                        .object([
                            "id": .string(call.callID),
                            "type": .string("function"),
                            "function": .object([
                                "name": .string(call.name),
                                "arguments": .string(call.arguments)
                            ])
                        ])
                    })
                ]))
            } else if !text.isEmpty, outputs.isEmpty {
                messages.append(.object([
                    "role": .string(role(for: item)),
                    "content": .string(text)
                ]))
            }
        }
        return messages
    }

    private static func role(for item: ConversationItem) -> String {
        item.role.rawValue
    }

    public static func tools(from descriptors: [CapabilityDescriptor]) -> [JSONValue] {
        descriptors.filter(\.isEnabled).map { descriptor in
            .object([
                "type": .string("function"),
                "function": .object([
                    "name": .string(ToolFunctionName.sanitized(descriptor.id)),
                    "description": .string(descriptor.summary),
                    "parameters": .object([
                        "type": .string(descriptor.schema.type),
                        "properties": .object(descriptor.schema.properties),
                        "required": .array(descriptor.schema.required.map(JSONValue.string))
                    ])
                ])
            ])
        }
    }
}

public enum ChatCompletionsError: Error, LocalizedError, Sendable {
    case transport(String)
    case http(Int, String)
    case decoding(String)

    public var errorDescription: String? {
        switch self {
        case .transport(let detail): "Chat completions transport error: \(detail)"
        case .http(let code, let detail): "Chat completions request failed (HTTP \(code)): \(detail)"
        case .decoding(let detail): "Could not read chat completions response: \(detail)"
        }
    }
}

/// Turns a stream of `/chat/completions` SSE chunks into the internal Responses
/// event sequence. Text deltas are forwarded as they arrive; tool-call fragments
/// (which arrive split across chunks by `index`) are accumulated and flushed as
/// `function_call` output items at `finish()`. Pure and value-typed so the whole
/// mapping is unit-testable without a network round-trip.
public struct ChatCompletionsStreamAccumulator {
    public let responseID: UUID

    public private(set) var messageID = UUID()
    private var didOpenMessage = false
    private var text = ""
    private var toolCalls = StreamingToolCallAssembler<Int>()
    private var usage: Usage?

    public init(responseID: UUID) {
        self.responseID = responseID
    }

    public mutating func start() -> [ResponseStreamEvent] {
        [.responseCreated(responseID: responseID), .responseInProgress(responseID: responseID)]
    }

    public mutating func consume(_ chunk: JSONValue) -> [ResponseStreamEvent] {
        var events: [ResponseStreamEvent] = []
        if let reportedUsage = Self.usage(from: chunk.pluginObjectValue?["usage"]) {
            usage = reportedUsage
        }
        let delta = chunk.pluginObjectValue?["choices"]?.pluginArrayValue?.first?
            .pluginObjectValue?["delta"]?.pluginObjectValue ?? [:]

        if let content = delta["content"]?.stringValue, !content.isEmpty {
            if !didOpenMessage {
                didOpenMessage = true
                events.append(.messageOutputItemAdded(responseID: responseID, messageID: messageID))
                events.append(.contentPartAdded(responseID: responseID, messageID: messageID))
            }
            text += content
            events.append(.outputTextDelta(responseID: responseID, messageID: messageID, delta: content))
        }

        if let reasoning = delta["reasoning_content"]?.stringValue ?? delta["reasoning"]?.stringValue,
           !reasoning.isEmpty {
            events.append(.reasoningTextDelta(responseID: responseID, messageID: messageID, delta: reasoning))
        }

        for call in delta["tool_calls"]?.pluginArrayValue ?? [] {
            accumulate(call)
        }
        return events
    }

    public mutating func finish() -> [ResponseStreamEvent] {
        var events: [ResponseStreamEvent] = []
        if didOpenMessage {
            events.append(.outputTextDone(responseID: responseID, messageID: messageID, text: text))
            events.append(.contentPartDone(responseID: responseID, messageID: messageID, text: text))
            events.append(.messageOutputItemDone(responseID: responseID, messageID: messageID, text: text))
        }
        let responseIDString = ResponsesAIOutputSpec.responseID(responseID)
        for (index, fragment) in toolCalls.ordered() {
            let itemID = "fc_\(UUID().uuidString)"
            let item = ResponseStreamEvent.OutputItemPayload(
                id: itemID,
                type: "function_call",
                status: "completed",
                name: fragment.name,
                callID: fragment.callID.isEmpty ? itemID : fragment.callID,
                arguments: fragment.arguments.isEmpty ? "{}" : fragment.arguments
            )
            events.append(ResponseStreamEvent(
                type: "response.output_item.added", responseID: responseIDString,
                itemID: itemID, outputIndex: index, item: item
            ))
            events.append(ResponseStreamEvent(
                type: "response.output_item.done", responseID: responseIDString,
                itemID: itemID, outputIndex: index, item: item
            ))
        }
        events.append(.responseCompleted(
            responseID: responseID,
            messageID: didOpenMessage ? messageID : nil,
            text: didOpenMessage ? text : nil,
            usage: usage
        ))
        return events
    }

    private mutating func accumulate(_ call: JSONValue) {
        guard let object = call.pluginObjectValue else { return }
        let index = Int(object["index"]?.pluginNumberValue ?? 0)
        let id = object["id"]?.stringValue ?? ""
        let function = object["function"]?.pluginObjectValue ?? [:]
        let name = function["name"]?.stringValue ?? ""
        toolCalls.register(key: index, name: name, callID: id)
        if let arguments = function["arguments"]?.stringValue {
            toolCalls.appendArguments(arguments, key: index, fallbackCallID: id)
        }
    }

    private static func usage(from value: JSONValue?) -> Usage? {
        guard let object = value?.pluginObjectValue else { return nil }
        let input = Int(object["prompt_tokens"]?.pluginNumberValue ?? 0)
        let output = Int(object["completion_tokens"]?.pluginNumberValue ?? 0)
        let total = Int(object["total_tokens"]?.pluginNumberValue ?? Double(input + output))
        return Usage(inputTokens: input, outputTokens: output, totalTokens: total, tokensPerSecond: nil)
    }
}
