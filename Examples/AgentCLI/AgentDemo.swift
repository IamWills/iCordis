import Foundation
import iCordisHTTP

/// `swift run icordis-demo` is offline. `--live` explicitly opts into a configured API.
@main
struct AgentDemo {
    static func main() async throws {
        let live = CommandLine.arguments.contains("--live")
        let environment = ProcessInfo.processInfo.environment
        var configuration = HostedResponsesAPISettings.blank()
        configuration.apiProtocol = .openAIChatCompletions
        configuration.baseURL = live ? environment["ICORDIS_BASE_URL"] ?? "" : "https://example.invalid/v1"
        configuration.model = live ? environment["ICORDIS_MODEL"] ?? "" : "offline-demo"
        configuration.apiKey = live ? environment["ICORDIS_API_KEY"] ?? "" : ""
        guard let model = HostedResponsesModel.descriptor(from: configuration, defaultModelID: nil) else {
            throw DemoError.configuration("Set ICORDIS_BASE_URL and ICORDIS_MODEL for --live.")
        }
        var settings = AppSettings.default
        settings.hostedResponsesAPIs = [configuration]
        let savedSettings = settings
        let modelService: ModelService
        if live {
            let runtime = ChatCompletionsRuntime(settings: { savedSettings })
            try await runtime.loadModel(model)
            modelService = .defaultProvider(runtime: runtime)
        } else {
            modelService = ModelService(activeModelID: { model.id }, loadModel: { _ in }, unloadModel: {},
                generate: { request in
                    let response = UUID(), message = UUID()
                    let text = request.protocolMetadata["william.request.kind"]?.stringValue == "agent_completion_judge"
                        ? #"{"status":"completed","reason":"answered","next_action":""}"#
                        : "Hello from iCordis! The model, agent loop, tools, and completion reviewer are plugins."
                    return AsyncThrowingStream { output in
                        output.yield(.responseEvent(.outputTextDelta(responseID: response, messageID: message, delta: text)))
                        output.yield(.responseEvent(.responseCompleted(responseID: response, messageID: message, text: text)))
                        output.finish()
                    }
                }, cancel: { _ in }, resolveTaskIntent: { _, _, _, task, _ in .newTask(task) })
        }
        let host = RuntimeHost(preset: Preset(id: "demo", name: "iCordis demo", plugins: [
            StandardAgentLoopPlugin(), AgentRequestShaperPlugin(), AgentCompletionPlugin(),
            DefaultModelProviderPlugin(service: modelService), ToolRuntimePlugin(), StandardPermissionPlugin()
        ]))
        do {
            let loop = try await host.service(RuntimeServices.agentLoop)
            let task = "Say hello and explain in one sentence what a plugin-based agent SDK does."
            let request = AgentLoopRequest(session: .draft(defaults: settings), task: task, model: model,
                settings: settings, capabilities: [], memory: .empty, resolvedTaskIntent: .newTask(task))
            for try await event in try await loop.run(request) {
                if case .responseEvent(let response) = event, response.type == "response.output_text.delta" {
                    print(response.delta ?? "", terminator: "")
                }
            }
            print()
            try await host.shutdown()
        } catch {
            try? await host.shutdown()
            throw error
        }
    }
}
private enum DemoError: Error { case configuration(String) }
