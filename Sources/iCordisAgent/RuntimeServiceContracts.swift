import Foundation
import iCordisKernel

/// Runtime service keys. The DSH/Cordis capability slots use the canonical DSH
/// slot names as their `ServiceID` (`model`, `agent-loop`, `tools.registry`, …)
/// so a DSH-provided implementation and a William-native one are interchangeable
/// in the same slot with no name translation. William-internal services that DSH
/// has no slot for keep the `william.` prefix. `DSHSlotRegistry` documents the
/// full slot ⇄ contract map.
public enum RuntimeServices {
  public static let continuation = ServiceKey<AgentContinuationService>(
    ServiceID("agent.continuation"))
  public static let toolBridge = ServiceKey<AgentToolBridgeService>(
    ServiceID("tools.script-bridge"))
  public static let agentProgress = ServiceKey<AgentProgressService>(ServiceID("agent.progress"))
  public static let agentCompletion = ServiceKey<AgentCompletionService>(
    ServiceID("agent.completion"))
  public static let model = ServiceKey<ModelService>(ServiceID("model"))
  /// Registry of pluggable inference backends. Backend plugins register into it;
  /// the model router reads it to route each request. Lets a backend be added or
  /// removed by mounting/unmounting its plugin.
  public static let modelBackends = ServiceKey<ModelBackendRegistry>(
    ServiceID("william.model-backends"))
  public static let agentLoop = ServiceKey<AgentLoopService>(ServiceID("agent-loop"))
  public static let toolCatalog = ServiceKey<ToolCatalogService>(ServiceID("tools.catalog"))
  public static let toolDiscovery = ServiceKey<ToolDiscoveryService>(ServiceID("tools.discovery"))
  public static let toolRegistry = ServiceKey<ToolRegistryService>(ServiceID("tools.registry"))
  public static let toolExecution = ServiceKey<ToolExecutionService>(ServiceID("tools.execution"))
  /// Registry of pluggable tool providers (builtin, mcp, skills, process, and
  /// any group peeled off the monolith). The native dispatch aggregates their
  /// descriptors and routes each call to the provider that handles it.
  public static let toolProviders = ServiceKey<ToolProviderRegistry>(
    ServiceID("william.tool-providers"))
  public static let session = ServiceKey<SessionService>(ServiceID("session"))
  public static let memory = ServiceKey<MemoryService>(ServiceID("memory"))
  public static let mcp = ServiceKey<MCPService>(ServiceID("mcp"))
  public static let skills = ServiceKey<SkillService>(ServiceID("skills"))
  public static let resourceDiscovery = ServiceKey<ResourceDiscoveryService>(
    ServiceID("rds.resources"))
  public static let capabilityDiscovery = ServiceKey<CapabilityDiscoveryService>(
    ServiceID("rds.capabilities"))
  public static let permission = ServiceKey<PermissionService>(ServiceID("permission"))
  public static let approval = ServiceKey<ApprovalService>(ServiceID("approval"))
  public static let transaction = ServiceKey<TransactionService>(ServiceID("transaction"))
  public static let delegation = ServiceKey<DelegationService>(ServiceID("delegation"))
  public static let systemPrompt = ServiceKey<SystemPromptService>(ServiceID("system-prompt"))
  public static let context = ServiceKey<ContextService>(ServiceID("context"))
  public static let observability = ServiceKey<ObservabilityService>(ServiceID("observability"))
  public static let platform = ServiceKey<PlatformService>(ServiceID("platform"))
  public static let sandbox = ServiceKey<SandboxService>(ServiceID("sandbox"))
  public static let pluginRegistry = ServiceKey<PluginRegistryService>(
    ServiceID("william.plugins.registry"))
  /// The single request-shaping seam: turns an `AgentModelRequestDraft` into an
  /// `AIRequest` via the canonical builder + the `model/request` waterfall, so
  /// the in-process loop and the DSH bridge produce identical requests.
  public static let requestShaper = ServiceKey<AgentRequestShaper>(
    ServiceID("william.request-shaper"))
  /// Manage Cordis/Koishi community plugins hosted by the live DSH agent
  /// (install/uninstall/enable/list). Provided only while a DSH runtime is
  /// mounted, since the plugins execute inside that agent.
}

public struct ModelService: WilliamService {
  public let activeModelID: @Sendable () async -> UUID?
  public let loadModel: @Sendable (LocalModelDescriptor) async throws -> Void
  public let unloadModel: @Sendable () async -> Void
  public let generate: @Sendable (AIRequest) async throws -> AsyncThrowingStream<StreamEvent, Error>
  public let cancel: @Sendable (UUID) async -> Void
  public let resolveTaskIntent:
    @Sendable (
      _ sessionID: UUID,
      _ modelID: UUID,
      _ session: ConversationSession,
      _ request: String,
      _ parameters: InferenceParameters
    ) async throws -> AgentTaskIntent

  public init(
    activeModelID: @escaping @Sendable () async -> UUID?,
    loadModel: @escaping @Sendable (LocalModelDescriptor) async throws -> Void,
    unloadModel: @escaping @Sendable () async -> Void,
    generate:
      @escaping @Sendable (AIRequest) async throws -> AsyncThrowingStream<StreamEvent, Error>,
    cancel: @escaping @Sendable (UUID) async -> Void,
    resolveTaskIntent:
      @escaping @Sendable (
        UUID,
        UUID,
        ConversationSession,
        String,
        InferenceParameters
      ) async throws -> AgentTaskIntent
  ) {
    self.activeModelID = activeModelID
    self.loadModel = loadModel
    self.unloadModel = unloadModel
    self.generate = generate
    self.cancel = cancel
    self.resolveTaskIntent = resolveTaskIntent
  }
}

public struct AgentLoopRequest: Sendable {
  public let session: ConversationSession
  public let task: String
  public let model: LocalModelDescriptor
  public let settings: AppSettings
  public let capabilities: [CapabilityDescriptor]
  public let memory: LongTermMemoryContext
  public let resolvedTaskIntent: AgentTaskIntent?
  /// The host-assembled conversation the run should be seeded with — system
  /// prompt + long-term memory + trimmed history + the current user turn, as
  /// produced by `PromptBuilder`. The in-process Standard loop rebuilds its own
  /// trajectory from `session` and ignores this; the out-of-process DSH loop,
  /// which cannot see the host trajectory, forwards it over the wire so the
  /// borrowed model sees the full context instead of only `task`.
  public let history: [ConversationItem]

  public init(
    session: ConversationSession,
    task: String,
    model: LocalModelDescriptor,
    settings: AppSettings,
    capabilities: [CapabilityDescriptor],
    memory: LongTermMemoryContext,
    resolvedTaskIntent: AgentTaskIntent?,
    history: [ConversationItem] = []
  ) {
    self.session = session
    self.task = task
    self.model = model
    self.settings = settings
    self.capabilities = capabilities
    self.memory = memory
    self.resolvedTaskIntent = resolvedTaskIntent
    self.history = history
  }
}

public struct AgentLoopService: WilliamService {
  public let pluginID: PluginID
  public let run:
    @Sendable (AgentLoopRequest) async throws -> AsyncThrowingStream<StreamEvent, Error>
  public let cancel: @Sendable (UUID) async -> Void

  public init(
    pluginID: PluginID = PluginID("william.agent-loop.external"),
    run:
      @escaping @Sendable (AgentLoopRequest) async throws -> AsyncThrowingStream<StreamEvent, Error>,
    cancel: @escaping @Sendable (UUID) async -> Void
  ) {
    self.pluginID = pluginID
    self.run = run
    self.cancel = cancel
  }

  public func identified(by pluginID: PluginID) -> AgentLoopService {
    AgentLoopService(pluginID: pluginID, run: run, cancel: cancel)
  }

}

public struct ToolCatalogService: WilliamService {
  public let descriptors: @Sendable () async throws -> [CapabilityDescriptor]

  public init(descriptors: @escaping @Sendable () async throws -> [CapabilityDescriptor]) {
    self.descriptors = descriptors
  }
}

public struct ToolDiscoveryService: WilliamService {
  public let discover:
    @Sendable (_ query: String, _ settings: AppSettings, _ limit: Int) async throws ->
      [CapabilityDescriptor]

  public init(
    discover:
      @escaping @Sendable (_ query: String, _ settings: AppSettings, _ limit: Int) async throws ->
      [CapabilityDescriptor]
  ) { self.discover = discover }
}

public struct ToolRegistryService: WilliamService {
  public let registered: @Sendable () async throws -> [CapabilityDescriptor]
  public let activated: @Sendable (_ sessionID: UUID) async -> [CapabilityDescriptor]
  public let activate:
    @Sendable (_ sessionID: UUID, _ capabilityIDs: Set<String>) async throws -> Void
  public let deactivate: @Sendable (_ sessionID: UUID, _ capabilityIDs: Set<String>) async -> Void

  public init(
    registered: @escaping @Sendable () async throws -> [CapabilityDescriptor],
    activated: @escaping @Sendable (_ sessionID: UUID) async -> [CapabilityDescriptor],
    activate:
      @escaping @Sendable (_ sessionID: UUID, _ capabilityIDs: Set<String>) async throws -> Void,
    deactivate: @escaping @Sendable (_ sessionID: UUID, _ capabilityIDs: Set<String>) async -> Void
  ) {
    self.registered = registered
    self.activated = activated
    self.activate = activate
    self.deactivate = deactivate
  }
}

public struct ToolExecutionService: WilliamService {
  public let invoke:
    @Sendable (CapabilityInvocationRequest, AppSettings) async throws -> CapabilityExecutionTrace
  public let parseInlineInvocation: @Sendable (String, UUID) async -> CapabilityInvocationRequest?

  public init(
    invoke:
      @escaping @Sendable (CapabilityInvocationRequest, AppSettings) async throws ->
      CapabilityExecutionTrace,
    parseInlineInvocation: @escaping @Sendable (String, UUID) async -> CapabilityInvocationRequest?
  ) {
    self.invoke = invoke
    self.parseInlineInvocation = parseInlineInvocation
  }
}

extension ToolExecutionService: CapabilityInvoking {
  public func executeCapability(
    _ request: CapabilityInvocationRequest,
    settings: AppSettings
  ) async throws -> CapabilityExecutionTrace {
    try await invoke(request, settings)
  }
}

public struct SessionService: WilliamService {
  public let list: @Sendable () async throws -> [ConversationSession]
  public let load: @Sendable (UUID) async throws -> ConversationSession
  public let save: @Sendable (ConversationSession) async throws -> Void
  public let delete: @Sendable (UUID) async throws -> Void
  public let runtimeSessionID: @Sendable (_ conversationID: UUID) -> UUID
  public let conversationID: @Sendable (_ runtimeSessionID: UUID) -> UUID
  public let append: @Sendable (RuntimeSessionEvent) async -> Void
  public let trajectory: @Sendable (UUID) async -> [RuntimeSessionEvent]
  public let resume: @Sendable (UUID) async -> [RuntimeSessionEvent]
  public let fork:
    @Sendable (_ sessionID: UUID, _ throughEventID: UUID?) async throws -> RuntimeSessionFork
  public let replay: @Sendable (_ sessionID: UUID) async -> AsyncStream<RuntimeSessionEvent>

  public init(
    list: @escaping @Sendable () async throws -> [ConversationSession],
    load: @escaping @Sendable (UUID) async throws -> ConversationSession,
    save: @escaping @Sendable (ConversationSession) async throws -> Void,
    delete: @escaping @Sendable (UUID) async throws -> Void,
    runtimeSessionID: @escaping @Sendable (_ conversationID: UUID) -> UUID,
    conversationID: @escaping @Sendable (_ runtimeSessionID: UUID) -> UUID,
    append: @escaping @Sendable (RuntimeSessionEvent) async -> Void,
    trajectory: @escaping @Sendable (UUID) async -> [RuntimeSessionEvent],
    resume: @escaping @Sendable (UUID) async -> [RuntimeSessionEvent],
    fork:
      @escaping @Sendable (_ sessionID: UUID, _ throughEventID: UUID?) async throws ->
      RuntimeSessionFork,
    replay: @escaping @Sendable (_ sessionID: UUID) async -> AsyncStream<RuntimeSessionEvent>
  ) {
    self.list = list
    self.load = load
    self.save = save
    self.delete = delete
    self.runtimeSessionID = runtimeSessionID
    self.conversationID = conversationID
    self.append = append
    self.trajectory = trajectory
    self.resume = resume
    self.fork = fork
    self.replay = replay
  }
}

public struct MemoryService: WilliamService {
  public let context: @Sendable (String, ConversationSession) async throws -> LongTermMemoryContext
  public let search:
    @Sendable (String, LongTermMemoryScope?, Int) async throws -> [LongTermMemoryRecord]
  public let remember: @Sendable (LongTermMemoryWriteRequest) async throws -> LongTermMemoryRecord
  public let forget: @Sendable (UUID) async throws -> Void

  public init(
    context:
      @escaping @Sendable (String, ConversationSession) async throws -> LongTermMemoryContext,
    search:
      @escaping @Sendable (String, LongTermMemoryScope?, Int) async throws -> [LongTermMemoryRecord],
    remember: @escaping @Sendable (LongTermMemoryWriteRequest) async throws -> LongTermMemoryRecord,
    forget: @escaping @Sendable (UUID) async throws -> Void
  ) {
    self.context = context
    self.search = search
    self.remember = remember
    self.forget = forget
  }
}

public struct MCPService: WilliamService {
  public let servers: @Sendable () async throws -> [MCPServerDescriptor]
  public let tools: @Sendable () async throws -> [CapabilityDescriptor]
  public let invoke:
    @Sendable (CapabilityInvocationRequest) async throws -> CapabilityInvocationResult

  public init(
    servers: @escaping @Sendable () async throws -> [MCPServerDescriptor],
    tools: @escaping @Sendable () async throws -> [CapabilityDescriptor],
    invoke:
      @escaping @Sendable (CapabilityInvocationRequest) async throws -> CapabilityInvocationResult
  ) {
    self.servers = servers
    self.tools = tools
    self.invoke = invoke
  }
}

public struct SkillService: WilliamService {
  public let discover: @Sendable () async throws -> [SkillDescriptor]
  public let tools: @Sendable () async throws -> [CapabilityDescriptor]
  public let load: @Sendable (String) async throws -> SkillDescriptor
  public let invoke:
    @Sendable (CapabilityInvocationRequest) async throws -> CapabilityInvocationResult

  public init(
    discover: @escaping @Sendable () async throws -> [SkillDescriptor],
    tools: @escaping @Sendable () async throws -> [CapabilityDescriptor],
    load: @escaping @Sendable (String) async throws -> SkillDescriptor,
    invoke:
      @escaping @Sendable (CapabilityInvocationRequest) async throws -> CapabilityInvocationResult
  ) {
    self.discover = discover
    self.tools = tools
    self.load = load
    self.invoke = invoke
  }
}

public struct ResourceDescriptor: Codable, Hashable, Identifiable, Sendable {
  public enum Kind: String, Codable, Sendable {
    case capability
    case skill
    case mcpResource
    case remote
  }

  public let id: String
  public let kind: Kind
  public let name: String
  public let summary: String
  public let metadata: [String: JSONValue]

  public init(id: String, kind: Kind, name: String, summary: String, metadata: [String: JSONValue])
  {
    self.id = id
    self.kind = kind
    self.name = name
    self.summary = summary
    self.metadata = metadata
  }
}

public struct ActivatedResource: Codable, Hashable, Sendable {
  public let resource: ResourceDescriptor
  public let capabilityIDs: Set<String>
  public let activatedAt: Date

  public init(resource: ResourceDescriptor, capabilityIDs: Set<String>, activatedAt: Date) {
    self.resource = resource
    self.capabilityIDs = capabilityIDs
    self.activatedAt = activatedAt
  }
}

public struct ResourceDiscoveryService: WilliamService {
  public let search: @Sendable (_ query: String, _ limit: Int) async throws -> [ResourceDescriptor]
  public let describe: @Sendable (String) async throws -> ResourceDescriptor
  public let activate: @Sendable (String, UUID) async throws -> ActivatedResource
  public let invoke:
    @Sendable (String, CapabilityInvocationRequest, AppSettings) async throws ->
      CapabilityExecutionTrace

  public init(
    search:
      @escaping @Sendable (_ query: String, _ limit: Int) async throws -> [ResourceDescriptor],
    describe: @escaping @Sendable (String) async throws -> ResourceDescriptor,
    activate: @escaping @Sendable (String, UUID) async throws -> ActivatedResource,
    invoke:
      @escaping @Sendable (String, CapabilityInvocationRequest, AppSettings) async throws ->
      CapabilityExecutionTrace
  ) {
    self.search = search
    self.describe = describe
    self.activate = activate
    self.invoke = invoke
  }
}

public struct CapabilityDiscoveryService: WilliamService {
  public let discover:
    @Sendable (_ query: String, _ settings: AppSettings, _ limit: Int) async throws ->
      [CapabilityDescriptor]

  public init(
    discover:
      @escaping @Sendable (_ query: String, _ settings: AppSettings, _ limit: Int) async throws ->
      [CapabilityDescriptor]
  ) { self.discover = discover }
}

public enum PermissionKind: String, Codable, CaseIterable, Sendable {
  case read
  case network
  case filesystem
  case write
  case system
  case externalAction
  case destructive
  case transaction
}

public enum PermissionDecision: String, Codable, Sendable {
  case allow
  case deny
  case askUser
}

public struct PermissionRequest: Codable, Hashable, Sendable {
  public let id: UUID
  public let pluginID: PluginID
  public let kind: PermissionKind
  public let resource: String
  public let reason: String

  public init(id: UUID, pluginID: PluginID, kind: PermissionKind, resource: String, reason: String)
  {
    self.id = id
    self.pluginID = pluginID
    self.kind = kind
    self.resource = resource
    self.reason = reason
  }
}

public struct PermissionService: WilliamService {
  public let evaluate: @Sendable (PermissionRequest) async -> PermissionDecision

  public init(evaluate: @escaping @Sendable (PermissionRequest) async -> PermissionDecision) {
    self.evaluate = evaluate
  }
}

public struct BusinessApprovalRequest: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let pluginID: PluginID
  public let title: String
  public let summary: String
  public let payload: JSONValue?

  public init(
    id: UUID, pluginID: PluginID, title: String, summary: String, payload: JSONValue? = nil
  ) {
    self.id = id
    self.pluginID = pluginID
    self.title = title
    self.summary = summary
    self.payload = payload
  }
}

public enum BusinessApprovalDecision: String, Codable, Sendable {
  case approved
  case denied
  case pending
}

public struct ApprovalService: WilliamService {
  public let request: @Sendable (BusinessApprovalRequest) async -> BusinessApprovalDecision

  public init(
    request: @escaping @Sendable (BusinessApprovalRequest) async -> BusinessApprovalDecision
  ) { self.request = request }
}

public struct TransactionAuthorizationRequest: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let pluginID: PluginID
  public let amount: Decimal
  public let currency: String
  public let counterparty: String
  public let purpose: String

  public init(
    id: UUID, pluginID: PluginID, amount: Decimal, currency: String, counterparty: String,
    purpose: String
  ) {
    self.id = id
    self.pluginID = pluginID
    self.amount = amount
    self.currency = currency
    self.counterparty = counterparty
    self.purpose = purpose
  }
}

public struct TransactionService: WilliamService {
  public let authorize:
    @Sendable (TransactionAuthorizationRequest) async -> BusinessApprovalDecision

  public init(
    authorize:
      @escaping @Sendable (TransactionAuthorizationRequest) async -> BusinessApprovalDecision
  ) { self.authorize = authorize }
}

public struct DelegationRequest: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let objective: String
  public let capabilityID: String
  public let payload: JSONValue?

  public init(id: UUID, objective: String, capabilityID: String, payload: JSONValue? = nil) {
    self.id = id
    self.objective = objective
    self.capabilityID = capabilityID
    self.payload = payload
  }
}

public struct DelegationService: WilliamService {
  public let create: @Sendable (DelegationRequest) async throws -> JSONValue

  public init(create: @escaping @Sendable (DelegationRequest) async throws -> JSONValue) {
    self.create = create
  }
}

public struct PromptFragment: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let priority: Int
  public let content: String

  public init(id: String, priority: Int, content: String) {
    self.id = id
    self.priority = priority
    self.content = content
  }
}

public struct SystemPromptService: WilliamService {
  public let assemble: @Sendable ([PromptFragment]) async throws -> String

  public init(assemble: @escaping @Sendable ([PromptFragment]) async throws -> String) {
    self.assemble = assemble
  }
}

public struct ContextContribution: Codable, Hashable, Identifiable, Sendable {
  public let id: String
  public let priority: Int
  public let content: String

  public init(id: String, priority: Int, content: String) {
    self.id = id
    self.priority = priority
    self.content = content
  }
}

public struct ContextService: WilliamService {
  public let assemble: @Sendable ([ContextContribution]) async throws -> String

  public init(assemble: @escaping @Sendable ([ContextContribution]) async throws -> String) {
    self.assemble = assemble
  }
}

public struct RuntimeObservation: Codable, Hashable, Identifiable, Sendable {
  public let id: UUID
  public let runID: UUID?
  public let sessionID: UUID?
  public let pluginID: PluginID
  public let category: String
  public let timestamp: Date
  public let metadata: [String: JSONValue]

  public init(
    id: UUID, runID: UUID? = nil, sessionID: UUID? = nil, pluginID: PluginID, category: String,
    timestamp: Date, metadata: [String: JSONValue]
  ) {
    self.id = id
    self.runID = runID
    self.sessionID = sessionID
    self.pluginID = pluginID
    self.category = category
    self.timestamp = timestamp
    self.metadata = metadata
  }
}

public struct ObservabilityService: WilliamService {
  public let record: @Sendable (RuntimeObservation) async -> Void
  public let observations: @Sendable (UUID?) async -> [RuntimeObservation]

  public init(
    record: @escaping @Sendable (RuntimeObservation) async -> Void,
    observations: @escaping @Sendable (UUID?) async -> [RuntimeObservation]
  ) {
    self.record = record
    self.observations = observations
  }
}

public struct PlatformService: WilliamService {
  public let platform: WilliamPlatform
  public let capabilities: Set<PluginCapability>

  public init(platform: WilliamPlatform, capabilities: Set<PluginCapability>) {
    self.platform = platform
    self.capabilities = capabilities
  }
}

public struct SandboxRequest: Codable, Hashable, Sendable {
  public let pluginID: PluginID
  public let operation: String
  public let resources: [String]

  public init(pluginID: PluginID, operation: String, resources: [String]) {
    self.pluginID = pluginID
    self.operation = operation
    self.resources = resources
  }
}

public struct SandboxService: WilliamService {
  public let validate: @Sendable (SandboxRequest) async -> PermissionDecision

  public init(validate: @escaping @Sendable (SandboxRequest) async -> PermissionDecision) {
    self.validate = validate
  }
}

public struct PluginRegistryService: WilliamService {
  public let installed: @Sendable () async -> [PluginRegistrySnapshot]
  public let enabled: @Sendable () async -> [PluginRegistrySnapshot]
  public let disabled: @Sendable () async -> [PluginRegistrySnapshot]
  public let failed: @Sendable () async -> [PluginRegistrySnapshot]

  public init(
    installed: @escaping @Sendable () async -> [PluginRegistrySnapshot],
    enabled: @escaping @Sendable () async -> [PluginRegistrySnapshot],
    disabled: @escaping @Sendable () async -> [PluginRegistrySnapshot],
    failed: @escaping @Sendable () async -> [PluginRegistrySnapshot]
  ) {
    self.installed = installed
    self.enabled = enabled
    self.disabled = disabled
    self.failed = failed
  }
}
