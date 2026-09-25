# Migration from William

The initial extraction moves the kernel, shared value contracts, default agent implementation, pure tool/discovery utilities, session log, model backend registry, provider plugins and Chat Completions HTTP backend into iCordis.

William retains UI, concrete storage implementations, application/tool services, OS-specific model engines, local process plugins, and DSH transports/community-plugin management.

## Host changes

1. Link iCordisAgent, or iCordisHTTP when using the HTTP adapter. Kernel-only applications link iCordisKernel.
2. Import the products instead of compiling the original source copies. Do not include duplicate definitions.
3. Implement AgentBuiltinToolProviding, AgentInstructionSkillProviding, AgentRegisteredAppProviding and other needed contracts on existing host services.
4. Register a ContinuationProviderPlugin for user interaction. Without one, the runtime ends incomplete when continuation needs a user decision.
5. If required, provide AgentToolBridgeService from a desktop-specific adapter. Own and stop its returned lease.
6. Supply ChatCompletionsRuntime with a Sendable settings-loading closure; the HTTP backend no longer depends on SettingsService.
7. Keep original William-specific service keys (UI, plugin installation, DSH) in an application extension of RuntimeServices.

William's NativeToolProviderPlugin assembles concrete tools and delegates middleware/registry wiring to ToolRuntimePlugin. StandardAgentLoopPlugin directly constructs the SDK runtime; William has no copied fallback loop.

The previous development HTTP endpoint is removed from shared defaults. Existing persisted endpoint settings are preserved by decoding; new hosts must configure their own provider. Prompts are package resources; applications can override resources through PromptStore.

The initial public surface retains legacy schema/type/identifier spellings to avoid rewriting persisted sessions or installed tool metadata. A rename is not needed to adopt the package.

## Tests

Kernel, action parser, invocation ledger, and Chat Completions runtime tests move with their implementation. Public-import integration tests additionally verify the actual default loop, provider removal, permission handling, and completion-provider replacement. William retains its application and cross-module regression tests.
