import Foundation
import Testing
import iCordisKernel

@Suite("William Plugin Kernel")
struct WilliamKernelTests {
  @Test func dependencyResolutionDoesNotDependOnMountOrder() async throws {
    let recorder = StringRecorder()
    let kernel = WilliamKernel()

    let pending = try await kernel.mount(GreetingConsumerPlugin(recorder: recorder))
    #expect(pending.state == .unresolved)
    #expect(pending.missingServices == [TestServices.greeting.id])

    _ = try await kernel.mount(GreetingProviderPlugin(value: "hello"))

    let active = await kernel.diagnostics().plugin(GreetingConsumerPlugin.manifest.id)
    #expect(active?.state == .active)
    #expect(await recorder.values() == ["apply:hello"])

    _ = try await kernel.unmount(GreetingProviderPlugin.manifest.id)

    let unresolved = await kernel.diagnostics().plugin(GreetingConsumerPlugin.manifest.id)
    #expect(unresolved?.state == .unresolved)
    #expect(unresolved?.missingServices == [TestServices.greeting.id])
    #expect(await recorder.values() == ["apply:hello", "dispose:consumer"])
  }

  @Test func optionalDependencyDoesNotBlockActivation() async throws {
    let recorder = StringRecorder()
    let kernel = WilliamKernel()

    let snapshot = try await kernel.mount(OptionalGreetingPlugin(recorder: recorder))

    #expect(snapshot.state == .active)
    #expect(await recorder.values() == ["optional:none"])
  }

  @Test func mountAndUnmountOwnServicesAndEventHandlers() async throws {
    let recorder = StringRecorder()
    let kernel = WilliamKernel()
    let event = NotificationEvent<String>(EventID("test/ping"))

    _ = try await kernel.mount(OwnedRegistrationPlugin(recorder: recorder, event: event))
    try await kernel.events.emit(event, payload: "one")
    #expect(await recorder.values() == ["event:one"])
    #expect(try await kernel.services.resolve(TestServices.greeting).value == "owned")

    _ = try await kernel.unmount(OwnedRegistrationPlugin.manifest.id)
    try await kernel.events.emit(event, payload: "two")

    #expect(await recorder.values() == ["event:one", "dispose:owned"])
    await #expect(throws: ServiceRegistryError.self) {
      _ = try await kernel.services.resolve(TestServices.greeting)
    }
    #expect(await kernel.events.snapshots().isEmpty)
  }

  @Test func failedApplyRollsBackEveryRegistration() async throws {
    let recorder = StringRecorder()
    let kernel = WilliamKernel()

    await #expect(throws: KernelTestError.self) {
      _ = try await kernel.mount(FailingPlugin(recorder: recorder))
    }

    let snapshot = await kernel.diagnostics().plugin(FailingPlugin.manifest.id)
    #expect(snapshot?.state == .failed)
    #expect(snapshot?.lastError?.contains("intentional") == true)
    #expect(await recorder.values() == ["dispose:failed"])
    await #expect(throws: ServiceRegistryError.self) {
      _ = try await kernel.services.resolve(TestServices.greeting)
    }
  }

  @Test func pluginCannotProvideAServiceMissingFromItsManifest() async throws {
    let kernel = WilliamKernel()

    await #expect(throws: PluginContextError.self) {
      _ = try await kernel.mount(UndeclaredServicePlugin())
    }

    let snapshot = await kernel.diagnostics().plugin(UndeclaredServicePlugin.manifest.id)
    #expect(snapshot?.state == .failed)
    await #expect(throws: ServiceRegistryError.self) {
      _ = try await kernel.services.resolve(TestServices.greeting)
    }
  }

  @Test func reloadDisposesThenReappliesPlugin() async throws {
    let recorder = StringRecorder()
    let kernel = WilliamKernel()

    _ = try await kernel.mount(ReloadablePlugin(recorder: recorder))
    let reloaded = try await kernel.reload(ReloadablePlugin.manifest.id)

    #expect(reloaded.state == .active)
    #expect(reloaded.activationCount == 2)
    #expect(await recorder.values() == ["apply", "dispose", "apply"])
  }

  @Test func suspendAndResumeAreReversible() async throws {
    let recorder = StringRecorder()
    let kernel = WilliamKernel()
    _ = try await kernel.mount(ReloadablePlugin(recorder: recorder))

    let suspended = try await kernel.suspend(ReloadablePlugin.manifest.id)
    #expect(suspended.state == .suspended)
    #expect(await recorder.values() == ["apply", "dispose"])

    let resumed = try await kernel.resume(ReloadablePlugin.manifest.id)
    #expect(resumed.state == .active)
    #expect(resumed.activationCount == 2)
    #expect(await recorder.values() == ["apply", "dispose", "apply"])
  }

  @Test func missingPluginDependencyIsDiagnosedDeterministically() async throws {
    let kernel = WilliamKernel()

    let snapshot = try await kernel.mount(MissingDependencyPlugin())

    #expect(snapshot.state == .unresolved)
    #expect(snapshot.missingPlugins == [PluginID("test.not-installed")])
  }

  @Test func explicitServiceReplacementRestoresPreviousProvider() async throws {
    let registry = ServiceRegistry()
    let scopeA = ScopeID()
    let scopeB = ScopeID()
    let pluginA = PluginID("test.provider.a")
    let pluginB = PluginID("test.provider.b")
    let first = try await registry.provide(
      GreetingService(value: "a"),
      for: TestServices.greeting,
      provider: pluginA,
      scopeID: scopeA
    )
    let replacement = try await registry.provide(
      GreetingService(value: "b"),
      for: TestServices.greeting,
      provider: pluginB,
      scopeID: scopeB,
      conflictPolicy: .replace
    )

    #expect(try await registry.resolve(TestServices.greeting).value == "b")
    await registry.remove(replacement)
    #expect(try await registry.resolve(TestServices.greeting).value == "a")
    await registry.remove(first)
    await #expect(throws: ServiceRegistryError.self) {
      _ = try await registry.resolve(TestServices.greeting)
    }
  }

  @Test func eventContractsHaveDeterministicOrderingAndComposition() async throws {
    let bus = EventBus()
    let recorder = StringRecorder()
    let owner = PluginID("test.events")
    let notification = NotificationEvent<String>(EventID("test/notification"))
    _ = try await bus.on(notification, owner: owner, priority: 0) { value in
      await recorder.append("low:\(value)")
    }
    _ = try await bus.on(notification, owner: owner, priority: 10) { value in
      await recorder.append("high:\(value)")
    }
    try await bus.emit(notification, payload: "x")
    #expect(await recorder.values() == ["high:x", "low:x"])

    let serial = SerialEvent<String, String>(EventID("test/serial"))
    _ = try await bus.on(serial, owner: owner) { _ in nil }
    _ = try await bus.on(serial, owner: owner) { "winner:\($0)" }
    _ = try await bus.on(serial, owner: owner) { "unreachable:\($0)" }
    #expect(try await bus.serial(serial, payload: "value") == "winner:value")

    let parallel = ParallelEvent<Int, Int>(EventID("test/parallel"))
    _ = try await bus.on(parallel, owner: owner, priority: 0) { $0 + 1 }
    _ = try await bus.on(parallel, owner: owner, priority: 10) { $0 + 2 }
    #expect(try await bus.parallel(parallel, payload: 3) == [5, 4])

    let transform = TransformEvent<String>(EventID("test/transform"))
    _ = try await bus.on(transform, owner: owner) { $0 + "a" }
    _ = try await bus.on(transform, owner: owner) { $0 + "b" }
    #expect(try await bus.transform(transform, initial: "x") == "xab")

    let middleware = MiddlewareEvent<String, String>(EventID("test/middleware"))
    _ = try await bus.on(middleware, owner: owner, priority: 10) { request, next in
      "[\(try await next(request + "a"))]"
    }
    _ = try await bus.on(middleware, owner: owner) { request, next in
      try await next(request + "b")
    }
    let result = try await bus.middleware(middleware, request: "x") { $0.uppercased() }
    #expect(result == "[XAB]")
  }

  @Test func effectAndNestedScopeCleanupIsReverseOrderedAndIdempotent() async throws {
    let recorder = StringRecorder()
    let parent = WilliamScope(kind: .conversation)
    let child = try await parent.makeChild(kind: .agentRun)
    try await child.effects.add(label: "child") {
      await recorder.append("child")
    }
    try await parent.effects.add(label: "parent") {
      await recorder.append("parent")
    }

    try await parent.dispose()
    try await parent.dispose()

    #expect(await recorder.values() == ["parent", "child"])
    #expect(await parent.snapshot().effects.state == .disposed)
    #expect(await child.snapshot().effects.state == .disposed)
  }

  @Test func lifecycleIsObservableAndDiagnosticsExplainOwnership() async throws {
    let kernel = WilliamKernel()
    let recorder = StateRecorder()
    let observer = try await kernel.events.on(
      KernelEvents.pluginLifecycle,
      owner: PluginID("test.observer")
    ) { observation in
      guard observation.pluginID == GreetingProviderPlugin.manifest.id else { return }
      await recorder.append(observation.state)
    }

    _ = try await kernel.mount(GreetingProviderPlugin(value: "hello"))
    let diagnostics = await kernel.diagnostics()

    #expect(
      diagnostics.provider(of: TestServices.greeting.id) == GreetingProviderPlugin.manifest.id)
    #expect(diagnostics.pluginScopes.count == 1)
    #expect(await recorder.values().contains(.loading))
    #expect(await recorder.values().contains(.applying))
    #expect(await recorder.values().contains(.active))
    await kernel.events.remove(observer)
  }

  @Test func kernelSourceHasNoBusinessRuntimeOrUnsafeConcurrencyDependencies() throws {
    let testFile = URL(fileURLWithPath: #filePath)
    let root =
      testFile
      .deletingLastPathComponent()
      .deletingLastPathComponent()
      .deletingLastPathComponent()
    let kernelDirectory = root.appendingPathComponent("Sources/iCordisKernel", isDirectory: true)
    let sources = try FileManager.default.contentsOfDirectory(
      at: kernelDirectory,
      includingPropertiesForKeys: nil
    ).filter { $0.pathExtension == "swift" }
    let forbidden = [
      "OpenAI", "Anthropic", "DeepSeek", "MCP", "Molobaya",
      "AgentLoop", "ToolRegistry", "ConversationSession", "MemoryService",
      "NotificationCenter", "DispatchQueue", "@unchecked Sendable",
    ]

    for source in sources {
      let contents = try String(contentsOf: source, encoding: .utf8)
      for token in forbidden {
        #expect(
          !contents.contains(token),
          "\(source.lastPathComponent) contains forbidden boundary token \(token)")
      }
    }
  }
}

private enum TestServices {
  static let greeting = ServiceKey<GreetingService>(ServiceID("test.greeting"))
}

private struct GreetingService: WilliamService {
  let value: String
}

private actor StringRecorder {
  private var storage: [String] = []

  func append(_ value: String) {
    storage.append(value)
  }

  func values() -> [String] { storage }
}

private actor StateRecorder {
  private var storage: [KernelPluginState] = []

  func append(_ value: KernelPluginState) {
    storage.append(value)
  }

  func values() -> [KernelPluginState] { storage }
}

private struct GreetingProviderPlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.greeting-provider"),
    name: "Greeting Provider",
    version: SemanticVersion(1),
    providedServices: [TestServices.greeting.id]
  )

  let value: String

  func apply(to context: PluginContext) async throws {
    try await context.provide(GreetingService(value: value), as: TestServices.greeting)
  }
}

private struct GreetingConsumerPlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.greeting-consumer"),
    name: "Greeting Consumer",
    version: SemanticVersion(1),
    requiredServices: [TestServices.greeting.id]
  )

  let recorder: StringRecorder

  func apply(to context: PluginContext) async throws {
    let greeting = try await context.service(TestServices.greeting)
    await recorder.append("apply:\(greeting.value)")
    try await context.effect(label: "consumer-cleanup") {
      await recorder.append("dispose:consumer")
    }
  }
}

private struct OptionalGreetingPlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.optional-greeting"),
    name: "Optional Greeting",
    version: SemanticVersion(1),
    optionalServices: [TestServices.greeting.id]
  )

  let recorder: StringRecorder

  func apply(to context: PluginContext) async throws {
    let greeting = try await context.optionalService(TestServices.greeting)
    await recorder.append("optional:\(greeting?.value ?? "none")")
  }
}

private struct OwnedRegistrationPlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.owned-registration"),
    name: "Owned Registration",
    version: SemanticVersion(1),
    providedServices: [TestServices.greeting.id]
  )

  let recorder: StringRecorder
  let event: NotificationEvent<String>

  func apply(to context: PluginContext) async throws {
    try await context.provide(GreetingService(value: "owned"), as: TestServices.greeting)
    try await context.on(event) { value in
      await recorder.append("event:\(value)")
    }
    try await context.effect(label: "owned-cleanup") {
      await recorder.append("dispose:owned")
    }
  }
}

private enum KernelTestError: Error, LocalizedError, Sendable {
  case intentional
  var errorDescription: String? { "intentional failure" }
}

private struct FailingPlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.failing"),
    name: "Failing",
    version: SemanticVersion(1),
    providedServices: [TestServices.greeting.id]
  )

  let recorder: StringRecorder

  func apply(to context: PluginContext) async throws {
    try await context.provide(GreetingService(value: "temporary"), as: TestServices.greeting)
    try await context.effect(label: "failed-cleanup") {
      await recorder.append("dispose:failed")
    }
    throw KernelTestError.intentional
  }
}

private struct UndeclaredServicePlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.undeclared-service"),
    name: "Undeclared Service",
    version: SemanticVersion(1)
  )

  func apply(to context: PluginContext) async throws {
    try await context.provide(GreetingService(value: "invalid"), as: TestServices.greeting)
  }
}

private struct ReloadablePlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.reloadable"),
    name: "Reloadable",
    version: SemanticVersion(1)
  )

  let recorder: StringRecorder

  func apply(to context: PluginContext) async throws {
    await recorder.append("apply")
    try await context.effect(label: "reload-cleanup") {
      await recorder.append("dispose")
    }
  }
}

private struct MissingDependencyPlugin: WilliamPlugin {
  static let manifest = PluginManifest(
    id: PluginID("test.missing-dependency"),
    name: "Missing Dependency",
    version: SemanticVersion(1),
    dependencies: [PluginDependency(id: PluginID("test.not-installed"))]
  )

  func apply(to context: PluginContext) async throws {}
}
