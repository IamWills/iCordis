import Foundation
import Testing
import iCordisAgent

private func demoModel() -> LocalModelDescriptor {
    LocalModelDescriptor(id: UUID(), displayName: "Test model", origin: .imported,
        format: .responsesAPI, modality: .text, path: "https://example.invalid/v1",
        sizeInBytes: 0, quantization: "", companionFiles: [], metadata: [:],
        compatibility: ModelCompatibility(state: .compatible, notes: "fixture"),
        isDefault: false, isCached: false, isLoaded: true, createdAt: .now, updatedAt: .now)
}
private actor Counter {
    var count = 0
    func increment() { count += 1 }
}

@Test func actualStandardLoopRunsWithOnlyPublicSDKPlugins() async throws {
    let model = demoModel()
    let requests = Counter()
    let service = ModelService(activeModelID: { model.id }, loadModel: { _ in }, unloadModel: {},
        generate: { request in
            await requests.increment()
            let response = UUID(), message = UUID()
            let text = request.protocolMetadata["william.request.kind"]?.stringValue == "agent_completion_judge"
                ? #"{"status":"completed","reason":"answered","next_action":""}"#
                : "Hello from iCordis."
            return AsyncThrowingStream { output in
                output.yield(.responseEvent(.responseCreated(responseID: response)))
                output.yield(.responseEvent(.outputTextDelta(responseID: response, messageID: message, delta: text)))
                output.yield(.responseEvent(.responseCompleted(responseID: response, messageID: message, text: text)))
                output.finish()
            }
        }, cancel: { _ in }, resolveTaskIntent: { _, _, _, task, _ in .newTask(task) })
    let host = RuntimeHost(preset: Preset(id: "test", name: "Test", plugins: [
        StandardAgentLoopPlugin(), AgentRequestShaperPlugin(), AgentCompletionPlugin(),
        DefaultModelProviderPlugin(service: service), ToolRuntimePlugin(), StandardPermissionPlugin()
    ]))
    let loop = try await host.service(RuntimeServices.agentLoop)
    let request = AgentLoopRequest(session: .draft(defaults: .default), task: "Say hello", model: model,
        settings: .default, capabilities: [], memory: .empty, resolvedTaskIntent: .newTask("Say hello"))
    var answer = ""
    var sawSummary = false
    for try await event in try await loop.run(request) {
        if case .responseEvent(let response) = event, response.type == "response.output_text.delta" {
            answer += response.delta ?? ""
        }
        if case .capabilityInvocation(let trace) = event, trace.request.capabilityID == "agent.run" {
            sawSummary = true
            #expect(trace.result.success)
        }
    }
    #expect(answer == "Hello from iCordis.")
    #expect(sawSummary)
    #expect(await requests.count >= 2)
    try await host.shutdown()
    #expect(await host.kernel.services.snapshots().isEmpty)
}

@Test func toolProviderUnmountAndAskUserPolicyAreEnforced() async throws {
    let calls = Counter()
    let kernel = Kernel()
    let permission = PermissionProviderPlugin(id: "test.permission", name: "Ask", service: PermissionService { _ in .askUser }, key: RuntimeServices.permission)
    _ = try await kernel.mount(permission)
    _ = try await kernel.mount(ToolRuntimePlugin())
    let provider = ToolProvider(id: "test.echo", descriptors: { _ in [] }, handles: { $0 == "test.echo" }, invoke: { request, _ in
        await calls.increment()
        return CapabilityInvocationResult(capabilityID: request.capabilityID, success: true, content: [.text("ok")], latency: 0)
    })
    let plugin = ToolProviderPlugin(provider: provider)
    _ = try await kernel.mount(plugin)
    let tools = try await kernel.services.resolve(RuntimeServices.toolExecution)
    let request = CapabilityInvocationRequest(sessionID: UUID(), capabilityID: "test.echo", arguments: [:], initiatedBy: .assistant)
    await #expect(throws: ToolPermissionError.self) { _ = try await tools.invoke(request, .default) }
    #expect(await calls.count == 0)
    _ = try await kernel.mount(PermissionProviderPlugin(id: "test.allow", name: "Allow", service: PermissionService { _ in .allow }, key: RuntimeServices.permission), conflictPolicy: .replace)
    let refreshed = try await kernel.services.resolve(RuntimeServices.toolExecution)
    // Existing service closures bind their permission provider until the consumer is reloaded.
    _ = refreshed
    _ = try await kernel.reload(ToolRuntimePlugin.manifest.id)
    let reloaded = try await kernel.services.resolve(RuntimeServices.toolExecution)
    _ = try await reloaded.invoke(request, .default)
    #expect(await calls.count == 1)
    _ = try await kernel.unmount(plugin.manifest.id)
    await #expect(throws: CapabilityInvocationError.self) { _ = try await reloaded.invoke(request, .default) }
    try await kernel.shutdown()
}

@Test func completionReplacementRestoresProviderAndParserHandlesUncertainty() async throws {
    let kernel = Kernel()
    let first = CompletionProviderPlugin(id: "review.first", name: "First", service: AgentCompletionService { _ in
        AgentCompletionDecision(shouldContinue: false, reason: "done")
    }, key: RuntimeServices.agentCompletion)
    let second = CompletionProviderPlugin(id: "review.second", name: "Second", service: AgentCompletionService { _ in
        AgentCompletionDecision(shouldContinue: true, reason: "more work", status: .continue, nextAction: "test")
    }, key: RuntimeServices.agentCompletion)
    _ = try await kernel.mount(first)
    _ = try await kernel.mount(second, conflictPolicy: .replace)
    #expect(await kernel.services.currentProvider(for: RuntimeServices.agentCompletion.id) == second.manifest.id)
    _ = try await kernel.unmount(second.manifest.id)
    #expect(await kernel.services.currentProvider(for: RuntimeServices.agentCompletion.id) == first.manifest.id)
    let uncertain = try AgentCompletionDecisionParser().parse(#"{"status":"continue","reason":"maybe","next_action":""}"#)
    #expect(uncertain.status == .needsUser)
    #expect(!uncertain.shouldContinue)
    try await kernel.shutdown()
}
