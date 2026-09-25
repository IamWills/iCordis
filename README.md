# iCordis

A Swift plugin kernel and plugin-based Agent SDK.

Model providers, agent loops, tool providers, sessions, memory, context, permissions, and completion review remain independently replaceable plugins. The kernel has no dependency on the Agent SDK or an inference engine.

**Status:** initial 0.1 release. Swift tools 6.0+, using Swift 5 language mode. Apple platforms: macOS 14+, iOS 17+, visionOS 1+. macOS tests and iOS Simulator builds are validated; visionOS runtime behavior has not yet been tested. Linux and Windows are not supported in this release.

## Products

| Product | Includes | Dependencies |
| --- | --- | --- |
| `iCordisKernel` | Lifecycle, typed services/events, dependency reconciliation, scopes/effects, configuration, diagnostics, preset host | Foundation |
| `iCordisAgent` | Default agent loop, native/text tool calling, discovery, context compression, execution ledger, completion review, session log, provider plugins and contracts | iCordisKernel, Apple system frameworks |
| `iCordisHTTP` | Optional streaming OpenAI-compatible Chat Completions adapter | iCordisAgent, URLSession |

No Node runtime, shell executor, downloadable native plugin loader, UI framework, model weights, MLX, LiteRT, or llama.cpp is included. Hosts may implement optional capabilities through service plugins.

## Install

Add `https://github.com/IamWills/iCordis.git` in Xcode's package dependencies, or:

```swift
.package(url: "https://github.com/IamWills/iCordis.git", from: "0.1.0")
```

Choose only the product you need in your target:

```swift
.product(name: "iCordisAgent", package: "iCordis")
```

The HTTP adapter re-exports the Agent SDK, which re-exports the kernel.

## Try the complete agent

```sh
git clone https://github.com/IamWills/iCordis.git
cd iCordis
swift test
swift run icordis-demo
```

The demo is **offline by default** and runs the actual default agent loop against a deterministic model plugin. See [the complete example](Examples/AgentCLI/AgentDemo.swift).

To explicitly use a real Chat Completions endpoint, configure `ICORDIS_BASE_URL` (including `/v1` when required), `ICORDIS_MODEL`, and optionally `ICORDIS_API_KEY` in your environment, then run:

```sh
swift run icordis-demo --live
```

The live demo sends its example prompt to that endpoint. Credentials are supplied by the host, never bundled by the SDK.

## Define a plugin

```swift
import iCordisKernel

struct Greeting: Service {
    let text: String
}
let greeting = ServiceKey<Greeting>(ServiceID("example.greeting"))
let kernel = Kernel()
let plugin = ServiceProviderPlugin(
    id: "example.greeting.provider", name: "Greeting",
    service: Greeting(text: "Hello"), key: greeting
)
try await kernel.mount(plugin)
let value = try await kernel.services.resolve(greeting)
print(value.text)
try await kernel.unmount(plugin.manifest.id)
```

`ServiceProviderPlugin` registers the supplied service as an owned effect. Use a custom `Plugin` implementation when a provider needs asynchronous startup, event middleware, dependencies, or several services. Declare every provided service in its manifest.

## Compose an agent

```swift
import iCordisAgent

// modelService is supplied by your application, or by iCordisHTTP.
let host = RuntimeHost(preset: Preset(id: "example.agent", name: "Agent", plugins: [
    StandardAgentLoopPlugin(),
    AgentRequestShaperPlugin(),
    AgentCompletionPlugin(),
    DefaultModelProviderPlugin(service: modelService),
    ToolRuntimePlugin(),
    StandardPermissionPlugin()
]))
let agent = try await host.service(RuntimeServices.agentLoop)
// Build an AgentLoopRequest and consume try await agent.run(request).
// Always stop the host when the owning application/session is finished.
try await host.shutdown()
```

Mount `ToolProviderPlugin` instances to add tools. Use `MemoryProviderPlugin`, `MCPProviderPlugin`, `SkillProviderPlugin`, or `SessionProviderPlugin` with host-owned service closures to add those capabilities. These aliases specialize `ServiceProviderPlugin`; supply the matching key from `RuntimeServices`. `LocalSessionPlugin` additionally offers a repository adapter and append-only event log.

For reversible replacement, use `kernel.mount(plugin, conflictPolicy: .replace)`. Unmounting reveals the previous provider. Consumers which cache a service must be reloaded to bind a replacement; resolving a service again reads the current provider. Lifecycle mutations should be awaited and serialized by the composition owner.

## Compatibility and scope

This first extraction intentionally preserves many William type names (`WilliamPlugin`, `WilliamKernel`, `ConversationSession`, `AppSettings`), tool IDs and wire keys to keep persisted conversations and host plugins compatible. Short names such as `Kernel`, `Plugin`, `Service`, `Preset`, and `RuntimeHost` are available. The models are shared value contracts; William's concrete UI, repositories, OS tools and app services are not included.

The `william.*` tool identifiers in the compatibility vocabulary do **not** install those tools. The default portable toolkit supplies discovery only. Applications choose the tool providers, prompts, permissions and storage they expose.

- [Architecture and plugin development](Docs/Architecture.md)
- [App Store integration boundaries](Docs/AppStore.md)
- [Migration from William](Docs/Migration.md)
- [Contributing](CONTRIBUTING.md)

## Provenance and license

iCordis is an independent Swift implementation extracted from William. Its lifecycle and service composition design is inspired by Cordis and DeepSeek Harness; it does not embed the upstream JavaScript Cordis runtime and does not claim binary or npm-plugin compatibility with it. Upstream Cordis plugins require an external host/bridge supplied by the application.

[MIT](LICENSE). The license applies to this repository's code and bundled documentation/prompts. Separately obtained models and third-party services retain their own terms.
