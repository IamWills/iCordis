# Architecture

Dependency direction is `iCordisHTTP → iCordisAgent → iCordisKernel`. Plugins implement typed services; applications select a preset rather than constructing a second runtime outside the plugin graph.

## Kernel

`Plugin` (`WilliamPlugin`) is a Sendable value with a manifest and asynchronous `apply(to:)`. Missing required plugins/services keep a mount unresolved. Mounting providers reconciles waiting consumers. Unmounting providers disposes dependants and their effects. Optional dependencies do not block startup.

`ServiceKey<T>` binds a stable service ID to a Swift service type. Replacement providers form a reversible stack. Registrations, event subscriptions and child scopes are owned by an `EffectScope`; disposal is awaited, reversed and idempotent. Diagnostics expose snapshots of ownership, replacement depth, missing dependencies and lifecycle state.

Events support notification, serial/bail, parallel, transformation and around middleware. Plugins should use `PluginContext.provide`, `on` and `effect` so teardown owns every registration. Low-level registries are exposed for composition/testing; directly registering with them requires manual ownership.

Kernel mounts are in-process, precompiled Swift code. They are not a security boundary or an executable installer. The initial origin policy permits `builtIn` and `localDevelopment`. A dependency included from an open-source Swift package can be a built-in provider in its host binary.

Serialize lifecycle mutations in the composition owner. Actor isolation protects stored state but does not make multi-await lifecycle transactions atomic. Event handlers should not recursively mutate the lifecycle while awaiting lifecycle dispatch. Provider replacement changes future resolutions; reload consumers that capture a provider at startup.

## Agent services and plugins

| Service | Default plugin or integration |
| --- | --- |
| `model` | DefaultModelProviderPlugin, LocalModelProviderPlugin, HostedResponsesModelPlugin |
| `agent-loop` | StandardAgentLoopPlugin; replace with MinimalAgentLoopPlugin or your implementation |
| `tools.catalog`, `tools.discovery`, `tools.registry`, `tools.execution`, `william.tool-providers` | ToolRuntimePlugin + ToolProviderPlugin contributions |
| `session` | LocalSessionPlugin or SessionProviderPlugin |
| `memory`, `mcp`, `skills` | MemoryProviderPlugin, MCPProviderPlugin, SkillProviderPlugin using host implementations |
| `agent.completion`, `agent.progress` | AgentCompletionPlugin; each service may be replaced separately |
| `agent.continuation` | Optional ContinuationProviderPlugin; defaults to declining further work when user input is required |
| `context`, `system-prompt`, `observability` | RuntimeCompositionPlugin or individual provider plugins |
| `permission`, `sandbox` | StandardPermissionPlugin or host policy |
| `approval`, `transaction` | SafeApprovalPlugin or explicit host implementation |
| `tools.script-bridge` | Optional host service; no script executor or loopback server ships in the SDK |

The StandardAgentLoopPlugin owns StandardAgentRuntime and shuts down its running tasks on disposal. The actual AgentLoop, request shaper, context compression, stream reducers, completion parser, and execution ledger were moved from William rather than replaced by a demonstration loop.

Default provider constructors accept host protocols (`AgentBuiltinToolProviding`, `AgentInstructionSkillProviding`, `AgentRegisteredAppProviding`, `AgentLocalAppInteracting`) or typed service closures. A service registration is not proof of an OS entitlement or user authorization.

Tool execution uses `tools/pre-execute`, `tools/execute`, and `tools/post-execute`. The portable ToolRuntimePlugin refuses `askUser` unless `providersHandleApproval` is explicitly enabled by a host whose providers enforce that interaction themselves. A host must never turn that flag on for unattended or untrusted tools.

## Session and prompts

RuntimeSessionEventLog is an append-only event log with trajectory, replay and fork operations. It is separate from transient EventBus events and from application-specific conversation persistence. SessionRepositoryProtocol is implemented by the host.

Prompt resources ship in the package. PromptStore supports an explicit bundle and development prompt directories. The compatibility prompts and data models preserve William's behavior; hosts can supply their own system prompts. No provider URL or API key is configured by default.

`AgentConfiguration.maxIterations` and `maxToolCalls` are legacy compatibility fields, not enforced spending limits in the current semantic completion loop. Hosts needing monetary or hard execution budgets must enforce them in their model/tool providers. Per-tool timeout and cancellation are enforced independently.

## Release strategy

0.x releases may refine public contracts. Keep the kernel independent of domain types. Prefer adding provider plugins over branches in the core loop. Put heavyweight inference engines and process execution integrations in separate packages rather than making all hosts resolve them.
