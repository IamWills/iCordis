import Foundation
import iCordisKernel

extension ModelService {
  public static func defaultProvider(runtime: any InferenceRuntimeProtocol) -> Self {
    Self(
      activeModelID: { await runtime.activeModelID() },
      loadModel: { try await runtime.loadModel($0) },
      unloadModel: { await runtime.unloadModel() },
      generate: { try await runtime.generate(request: $0) },
      cancel: { await runtime.cancelGeneration(sessionID: $0) },
      resolveTaskIntent: { sessionID, modelID, session, request, parameters in
        try await AgentLLMClient(runtime: runtime).resolveTaskIntent(
          sessionID: sessionID,
          modelID: modelID,
          session: session,
          currentRequest: request,
          parameters: parameters
        )
      }
    )
  }
}

extension AgentLoopService {
  public static func standard(agent: StandardAgentRuntime) -> Self {
    Self(
      pluginID: StandardAgentLoopPlugin.manifest.id,
      run: { request in
        try await agent.run(
          session: request.session,
          task: request.task,
          model: request.model,
          settings: request.settings,
          capabilityDescriptors: request.capabilities,
          memoryContext: request.memory,
          resolvedTaskIntent: request.resolvedTaskIntent
        )
      },
      cancel: { await agent.cancelGeneration(sessionID: $0) }
    )
  }
}

private actor PluginModelRuntimeAdapter: InferenceRuntimeProtocol {
  let model: ModelService

  init(model: ModelService) {
    self.model = model
  }

  func activeModelID() async -> UUID? { await model.activeModelID() }
  func loadModel(_ descriptor: LocalModelDescriptor) async throws {
    try await model.loadModel(descriptor)
  }
  func unloadModel() async { await model.unloadModel() }
  func generate(request: AIRequest) async throws -> AsyncThrowingStream<StreamEvent, Error> {
    try await model.generate(request)
  }
  func cancelGeneration(sessionID: UUID) async { await model.cancel(sessionID) }
}

/// Provides the single request-shaping seam. It builds the canonical model
/// request and runs it through the `RuntimeEvents.modelRequest` waterfall, so any
/// plugin can transform requests (Cordis-style middleware) and every caller —
/// in-process loop and DSH bridge alike — shapes requests one identical way.

public struct AgentRequestShaperPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.request-shaper"),
    name: "Agent Request Shaper",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent-request")],
    providedServices: [RuntimeServices.requestShaper.id]
  )

  public func apply(to context: PluginContext) async throws {
    let events = context.events
    try await context.provide(
      AgentRequestShaper { draft in
        let base = AgentTurnRequestBuilder.build(draft)
        return try await events.middleware(
          RuntimeEvents.modelRequest,
          request: base,
          terminal: { $0 }
        )
      },
      as: RuntimeServices.requestShaper
    )
  }

  public init() {}
}

public struct DefaultModelProviderPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.model.default"),
    name: "Default Model Provider",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("model")],
    providedServices: [RuntimeServices.model.id]
  )

  public let service: ModelService

  public func apply(to context: PluginContext) async throws {
    try await context.provide(service, as: RuntimeServices.model)
  }

  public init(service: ModelService) { self.service = service }
}

public struct LocalModelProviderPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.model.local"),
    name: "Local Model Provider",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("model"), PluginCapability("model.local")],
    providedServices: [RuntimeServices.model.id]
  )

  public let service: ModelService

  public func apply(to context: PluginContext) async throws {
    try await context.provide(service, as: RuntimeServices.model)
  }

  public init(service: ModelService) { self.service = service }
}

public struct HostedResponsesModelPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.model.hosted-responses"),
    name: "Hosted Responses Model Provider",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("model"), PluginCapability("model.hosted")],
    providedServices: [RuntimeServices.model.id],
    permissions: [.network]
  )

  public let service: ModelService

  public func apply(to context: PluginContext) async throws {
    try await context.provide(service, as: RuntimeServices.model)
  }

  public init(service: ModelService) { self.service = service }
}

public enum ToolPermissionError: Error, LocalizedError, Sendable, Equatable {
  case denied(String)

  public var errorDescription: String? {
    switch self {
    case .denied(let capabilityID):
      "Permission policy denied capability \(capabilityID)."
    }
  }
}

public struct StandardAgentLoopPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.agent-loop.standard"),
    name: "Standard Agent Loop",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent-loop.standard")],
    requiredServices: [
      RuntimeServices.model.id,
      RuntimeServices.toolDiscovery.id,
      RuntimeServices.toolExecution.id,
    ],
    optionalServices: [RuntimeServices.requestShaper.id],
    providedServices: [RuntimeServices.agentLoop.id]
  )

  private enum Implementation: Sendable {
    case supplied(AgentLoopService)
    case native(
      builtinRegistry: any AgentBuiltinToolProviding,
      instructionSkills: (any AgentInstructionSkillProviding)?,
      registeredApps: (any AgentRegisteredAppProviding)?,
      localAppInteractor: (any AgentLocalAppInteracting)?,
      configuration: AgentConfiguration
    )
  }

  private let implementation: Implementation

  public init(service: AgentLoopService) {
    implementation = .supplied(service)
  }

  public init(
    builtinRegistry: any AgentBuiltinToolProviding = StandardAgentTools(),
    instructionSkills: (any AgentInstructionSkillProviding)? = nil,
    registeredApps: (any AgentRegisteredAppProviding)? = nil,
    localAppInteractor: (any AgentLocalAppInteracting)? = nil,
    configuration: AgentConfiguration = .production
  ) {
    implementation = .native(
      builtinRegistry: builtinRegistry,
      instructionSkills: instructionSkills,
      registeredApps: registeredApps,
      localAppInteractor: localAppInteractor,
      configuration: configuration
    )
  }

  public func apply(to context: PluginContext) async throws {
    let model = try await context.service(RuntimeServices.model)
    _ = try await context.service(RuntimeServices.toolDiscovery)
    let toolExecution = try await context.service(RuntimeServices.toolExecution)
    let requestShaper =
      try await context.optionalService(RuntimeServices.requestShaper) ?? .passthrough
    let service: AgentLoopService
    switch implementation {
    case .supplied(let supplied):
      service = supplied.identified(by: Self.manifest.id)
    case .native(
      let builtinRegistry,
      let instructionSkills,
      let registeredApps,
      let localAppInteractor,
      let configuration
    ):
      let agent = StandardAgentRuntime(
        runtime: PluginModelRuntimeAdapter(model: model),
        orchestrator: toolExecution,
        builtinRegistry: builtinRegistry,
        instructionSkillService: instructionSkills,
        registeredAppService: registeredApps,
        localAppInteractor: localAppInteractor,
        configuration: configuration,
        requestShaper: requestShaper,
        services: context.services
      )
      service = .standard(agent: agent)
      try await context.effect(label: "standard-agent-runtime.shutdown") {
        await agent.shutdown()
      }
    }
    try await context.provide(service, as: RuntimeServices.agentLoop)
  }
}

public struct MinimalAgentLoopPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.agent-loop.minimal"),
    name: "Minimal Agent Loop",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent-loop.minimal")],
    requiredServices: [RuntimeServices.model.id],
    providedServices: [RuntimeServices.agentLoop.id]
  )

  public let service: AgentLoopService

  public func apply(to context: PluginContext) async throws {
    _ = try await context.service(RuntimeServices.model)
    try await context.provide(
      service.identified(by: Self.manifest.id),
      as: RuntimeServices.agentLoop
    )
  }

  public init(service: AgentLoopService) { self.service = service }
}

public struct LocalSessionPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.session.local"),
    name: "Local Session",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("session"), PluginCapability("trajectory")],
    providedServices: [RuntimeServices.session.id]
  )

  public let repository: any SessionRepositoryProtocol
  public let eventLog: RuntimeSessionEventLog

  public func apply(to context: PluginContext) async throws {
    let service = SessionService(
      list: { try await repository.listSessions() },
      load: { try await repository.loadSession(id: $0) },
      save: { try await repository.saveSession($0) },
      delete: { try await repository.deleteSession(id: $0) },
      runtimeSessionID: { RuntimeSessionIdentity.runtimeSessionID(for: $0) },
      conversationID: { RuntimeSessionIdentity.conversationID(for: $0) },
      append: { await eventLog.append($0) },
      trajectory: { await eventLog.trajectory(sessionID: $0) },
      resume: { await eventLog.trajectory(sessionID: $0) },
      fork: { sessionID, throughEventID in
        let sourceConversationID = RuntimeSessionIdentity.conversationID(for: sessionID)
        let forkedConversationID = UUID()
        let forkedRuntimeSessionID = RuntimeSessionIdentity.runtimeSessionID(
          for: forkedConversationID)
        let fork = await eventLog.fork(
          sessionID: sessionID,
          throughEventID: throughEventID,
          forkedSessionID: forkedRuntimeSessionID
        )
        var session = try await repository.loadSession(id: sourceConversationID)
        session.id = forkedConversationID
        session.title += " (Fork)"
        session.createdAt = .now
        session.updatedAt = .now
        try await repository.saveSession(session)
        return fork
      },
      replay: { sessionID in
        let events = await eventLog.trajectory(sessionID: sessionID)
        return eventLog.replay(events)
      }
    )
    try await context.provide(service, as: RuntimeServices.session)
  }

  public init(repository: any SessionRepositoryProtocol, eventLog: RuntimeSessionEventLog) {
    self.repository = repository
    self.eventLog = eventLog
  }
}

public struct StandardPermissionPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.permission.standard"),
    name: "Standard Permission Policy",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("permission")],
    providedServices: [RuntimeServices.permission.id, RuntimeServices.sandbox.id]
  )

  public func apply(to context: PluginContext) async throws {
    let permission = PermissionService { request in
      switch request.kind {
      case .read:
        .allow
      case .network, .filesystem, .write, .system, .externalAction, .destructive, .transaction:
        .askUser
      }
    }
    let sandbox = SandboxService { request in
      request.operation.hasPrefix("read") && request.resources.allSatisfy { !$0.isEmpty }
        ? .allow
        : .askUser
    }
    try await context.provide(permission, as: RuntimeServices.permission)
    try await context.provide(sandbox, as: RuntimeServices.sandbox)
  }

  public init() {}
}

public struct SafeApprovalPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.approval.safe"),
    name: "Safe Business Approval",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("approval"), PluginCapability("transaction")],
    providedServices: [RuntimeServices.approval.id, RuntimeServices.transaction.id]
  )

  public func apply(to context: PluginContext) async throws {
    try await context.provide(
      ApprovalService { _ in .pending },
      as: RuntimeServices.approval
    )
    try await context.provide(
      TransactionService { _ in .pending },
      as: RuntimeServices.transaction
    )
  }

  public init() {}
}

private actor RuntimeObservationStore {
  private var values: [RuntimeObservation] = []

  func record(_ value: RuntimeObservation) {
    values.append(value)
  }

  func observations(runID: UUID?) -> [RuntimeObservation] {
    values.filter { runID == nil || $0.runID == runID }
  }
}

public struct RuntimeCompositionPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.runtime.composition"),
    name: "Runtime Composition",
    version: SemanticVersion(1),
    capabilities: [
      PluginCapability("context"), PluginCapability("system-prompt"),
      PluginCapability("observability"),
    ],
    providedServices: [
      RuntimeServices.systemPrompt.id,
      RuntimeServices.context.id,
      RuntimeServices.observability.id,
    ]
  )

  private let observations = RuntimeObservationStore()

  public func apply(to context: PluginContext) async throws {
    let prompt = SystemPromptService { fragments in
      fragments.sorted { lhs, rhs in
        lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority > rhs.priority
      }.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    let contextService = ContextService { contributions in
      contributions.sorted { lhs, rhs in
        lhs.priority == rhs.priority ? lhs.id < rhs.id : lhs.priority > rhs.priority
      }.map(\.content).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }
    let observability = ObservabilityService(
      record: { await observations.record($0) },
      observations: { await observations.observations(runID: $0) }
    )
    try await context.provide(prompt, as: RuntimeServices.systemPrompt)
    try await context.provide(contextService, as: RuntimeServices.context)
    try await context.provide(observability, as: RuntimeServices.observability)
  }

  public init() {}
}

public struct KernelPluginRegistryPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.plugins.registry"),
    name: "Kernel Plugin Registry",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("plugin-registry")],
    providedServices: [RuntimeServices.pluginRegistry.id]
  )

  public let registry: PluginRegistry

  public func apply(to context: PluginContext) async throws {
    let service = PluginRegistryService(
      installed: { await registry.snapshots() },
      enabled: { await registry.snapshots().filter { $0.state == .active } },
      disabled: {
        await registry.snapshots().filter { [.suspended, .unloaded].contains($0.state) }
      },
      failed: { await registry.snapshots().filter { $0.state == .failed } }
    )
    try await context.provide(service, as: RuntimeServices.pluginRegistry)
  }

  public init(registry: PluginRegistry) { self.registry = registry }
}
