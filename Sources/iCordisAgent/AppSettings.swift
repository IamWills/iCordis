import Foundation
import iCordisKernel

public enum DefaultSessionModelSource: String, Codable, CaseIterable, Sendable {
  case localModel
  case hostedAPI
}

public enum AutonomousSkillLearningMode: String, Codable, CaseIterable, Hashable, Sendable {
  case off
  case draftOnly
  case autonomousPublish

  public var displayName: String {
    switch self {
    case .off: "Off"
    case .draftOnly: "Draft Only"
    case .autonomousPublish: "Autonomous Publish"
    }
  }
}

/// The wire protocol a configured hosted endpoint speaks. `responsesEnvelope` is
/// William's own ResponsesAI format (server-managed context via conversation_id,
/// custom events). `openAIChatCompletions` is the standard stateless
/// `/chat/completions` API (OpenAI, DeepSeek, …); William adapts it up to the
/// internal Responses event contract and owns the conversation context locally.
public enum HostedAPIProtocol: String, Codable, Sendable, CaseIterable {
  case responsesEnvelope
  case openAIChatCompletions

  public var displayName: String {
    switch self {
    case .responsesEnvelope: "ResponsesAI (envelope)"
    case .openAIChatCompletions: "OpenAI-compatible (chat completions)"
    }
  }
}

public struct HostedResponsesAPISettings: Codable, Hashable, Identifiable, Sendable {
  /// Stable model ID used when a legacy single-object setting is migrated.
  public static let legacyModelID = UUID(uuidString: "7F65D2D8-2B6F-4B66-9A62-9C03D4F4A9C1")!

  public var id: UUID
  /// Which wire protocol this endpoint speaks. Defaults to the ResponsesAI
  /// envelope for backward compatibility with settings saved before route B.
  public var apiProtocol: HostedAPIProtocol
  public var baseURL: String
  /// Optional full URL (or URL template containing `{conversation_id}`) used
  /// to restore server-side conversation history. When omitted, William uses
  /// the standard ResponsesAI `/zyw/conversations/{conversation_id}/history`
  /// endpoint derived from `baseURL`.
  public var conversationHistoryURL: String
  /// ResponsesAI company / provider segment, e.g. `Deepseek`.
  public var company: String
  public var model: String
  public var apiKey: String
  public var providerLabel: String

  public static let `default` = HostedResponsesAPISettings(
    id: legacyModelID,
    apiProtocol: .responsesEnvelope,
    baseURL: "",
    conversationHistoryURL: "",
    company: "",
    model: "",
    apiKey: "",
    providerLabel: "ResponsesAI"
  )

  public static func blank() -> HostedResponsesAPISettings {
    HostedResponsesAPISettings(
      id: UUID(),
      apiProtocol: .responsesEnvelope,
      baseURL: `default`.baseURL,
      conversationHistoryURL: "",
      company: "",
      model: "",
      apiKey: "",
      providerLabel: `default`.providerLabel
    )
  }

  public var normalizedBaseURL: String {
    baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedCompany: String {
    company.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedModel: String {
    model.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// ResponsesAI calls models as `Company:Model`, e.g. `Deepseek:Deepseek-4-flash`.
  public var resolvedModelName: String {
    let company = normalizedCompany
    let model = normalizedModel
    if model.contains(":") {
      return model
    }
    if !company.isEmpty, !model.isEmpty {
      return "\(company):\(model)"
    }
    return model
  }

  public var backendLabel: String {
    if !normalizedCompany.isEmpty {
      return normalizedCompany
    }
    if !normalizedProviderLabel.isEmpty {
      return normalizedProviderLabel
    }
    return "Responses API"
  }

  public var normalizedConversationHistoryURL: String {
    conversationHistoryURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedAPIKey: String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedProviderLabel: String {
    providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isConfigured: Bool {
    !normalizedBaseURL.isEmpty && !normalizedModel.isEmpty
  }

  public var displayTitle: String {
    if !resolvedModelName.isEmpty {
      return resolvedModelName
    }
    if !normalizedCompany.isEmpty {
      return normalizedCompany
    }
    if !normalizedProviderLabel.isEmpty {
      return normalizedProviderLabel
    }
    return "New Hosted API"
  }

  public init(
    id: UUID = legacyModelID,
    apiProtocol: HostedAPIProtocol = .responsesEnvelope,
    baseURL: String,
    conversationHistoryURL: String = "",
    company: String = "",
    model: String,
    apiKey: String,
    providerLabel: String
  ) {
    self.id = id
    self.apiProtocol = apiProtocol
    self.baseURL = baseURL
    self.conversationHistoryURL = conversationHistoryURL
    self.company = company
    self.model = model
    self.apiKey = apiKey
    self.providerLabel = providerLabel
    expandCombinedModelIfNeeded()
  }

  public func normalized() -> HostedResponsesAPISettings {
    var copy = self
    copy.expandCombinedModelIfNeeded()
    copy.baseURL = copy.normalizedBaseURL
    copy.conversationHistoryURL = copy.normalizedConversationHistoryURL
    copy.company = copy.normalizedCompany
    copy.model = copy.normalizedModel
    copy.apiKey = copy.normalizedAPIKey
    copy.providerLabel = copy.normalizedProviderLabel
    return copy
  }

  public mutating func expandCombinedModelIfNeeded() {
    guard normalizedCompany.isEmpty,
      let parsed = Self.parseCombinedModel(normalizedModel)
    else {
      return
    }
    company = parsed.company
    model = parsed.model
  }

  public static func parseCombinedModel(_ raw: String) -> (company: String, model: String)? {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard let separator = trimmed.firstIndex(of: ":") else {
      return nil
    }
    let company = String(trimmed[..<separator]).trimmingCharacters(in: .whitespacesAndNewlines)
    let model = String(trimmed[trimmed.index(after: separator)...])
      .trimmingCharacters(in: .whitespacesAndNewlines)
    guard !company.isEmpty, !model.isEmpty else {
      return nil
    }
    return (company, model)
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    id = try container.decodeIfPresent(UUID.self, forKey: .id) ?? Self.legacyModelID
    apiProtocol =
      try container.decodeIfPresent(HostedAPIProtocol.self, forKey: .apiProtocol)
      ?? defaults.apiProtocol
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
    conversationHistoryURL =
      try container.decodeIfPresent(String.self, forKey: .conversationHistoryURL)
      ?? defaults.conversationHistoryURL
    company = try container.decodeIfPresent(String.self, forKey: .company) ?? defaults.company
    model = try container.decodeIfPresent(String.self, forKey: .model) ?? defaults.model
    apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
    providerLabel =
      try container.decodeIfPresent(String.self, forKey: .providerLabel) ?? defaults.providerLabel
    expandCombinedModelIfNeeded()
  }
}

public struct RemoteCodeExecutionSettings: Codable, Hashable, Sendable {
  public var baseURL: String
  public var apiKey: String
  public var deviceID: String
  public var deviceName: String
  public var enableRemoteDispatchFromIOS: Bool
  public var enableMacRunner: Bool
  public var macRunnerRequiresConfirmation: Bool
  public var pollIntervalSeconds: TimeInterval

  public static let `default` = RemoteCodeExecutionSettings(
    baseURL: "",
    apiKey: "",
    deviceID: UUID().uuidString,
    deviceName: Self.defaultDeviceName(),
    enableRemoteDispatchFromIOS: false,
    enableMacRunner: false,
    macRunnerRequiresConfirmation: false,
    pollIntervalSeconds: 5
  )

  public var normalizedBaseURL: String {
    baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedAPIKey: String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isConfigured: Bool {
    !normalizedBaseURL.isEmpty && !normalizedAPIKey.isEmpty && URL(string: normalizedBaseURL) != nil
  }

  public static func defaultDeviceName() -> String {
    #if os(macOS)
      return Host.current().localizedName ?? "William Device"
    #else
      return "William Device"
    #endif
  }

  public init(
    baseURL: String,
    apiKey: String,
    deviceID: String,
    deviceName: String,
    enableRemoteDispatchFromIOS: Bool,
    enableMacRunner: Bool,
    macRunnerRequiresConfirmation: Bool,
    pollIntervalSeconds: TimeInterval
  ) {
    self.baseURL = baseURL
    self.apiKey = apiKey
    self.deviceID = deviceID
    self.deviceName = deviceName
    self.enableRemoteDispatchFromIOS = enableRemoteDispatchFromIOS
    self.enableMacRunner = enableMacRunner
    self.macRunnerRequiresConfirmation = macRunnerRequiresConfirmation
    self.pollIntervalSeconds = pollIntervalSeconds
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    baseURL = try container.decodeIfPresent(String.self, forKey: .baseURL) ?? defaults.baseURL
    apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
    deviceID = try container.decodeIfPresent(String.self, forKey: .deviceID) ?? defaults.deviceID
    deviceName =
      try container.decodeIfPresent(String.self, forKey: .deviceName) ?? defaults.deviceName
    enableRemoteDispatchFromIOS =
      try container.decodeIfPresent(Bool.self, forKey: .enableRemoteDispatchFromIOS)
      ?? defaults.enableRemoteDispatchFromIOS
    enableMacRunner =
      try container.decodeIfPresent(Bool.self, forKey: .enableMacRunner) ?? defaults.enableMacRunner
    macRunnerRequiresConfirmation =
      try container.decodeIfPresent(Bool.self, forKey: .macRunnerRequiresConfirmation)
      ?? defaults.macRunnerRequiresConfirmation
    pollIntervalSeconds =
      try container.decodeIfPresent(TimeInterval.self, forKey: .pollIntervalSeconds)
      ?? defaults.pollIntervalSeconds
  }
}

/// Configuration for filling the `agent-loop` slot with a DSH runtime instead of
/// the in-process Standard loop. When enabled and configured, the DSH plugin is
/// offered in the Kernel mountable catalog so the agent can `replace` the live
/// agent-loop with it (and back). Remote works on iOS + macOS; local is macOS.
public struct DSHRuntimeSettings: Codable, Hashable, Sendable {
  public enum Transport: String, Codable, Sendable {
    case remote
    case local
  }

  public var enabled: Bool
  public var transport: Transport
  public var endpoint: String
  public var authToken: String
  public var allowInsecureLoopback: Bool
  public var executablePath: String
  public var arguments: [String]

  // DSH is the intended default agent runtime, driven by a local
  // `dsh-jsonrpc-agent`. The executable path is left empty on purpose: until
  // the user points Settings at a real agent, `isConfigured` stays false and
  // the in-process Standard loop remains active, so a fresh install is not
  // broken by a runtime that cannot be reached. The Settings UI surfaces the
  // "not configured" state so the default reads as opt-in-once, not silent.
  public static let `default` = DSHRuntimeSettings(
    enabled: true,
    transport: .local,
    endpoint: "",
    authToken: "",
    allowInsecureLoopback: false,
    executablePath: "",
    arguments: []
  )

  public var normalizedEndpoint: String { endpoint.trimmingCharacters(in: .whitespacesAndNewlines) }
  public var normalizedToken: String { authToken.trimmingCharacters(in: .whitespacesAndNewlines) }
  public var normalizedExecutablePath: String {
    executablePath.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isRemoteConfigured: Bool {
    guard let url = URL(string: normalizedEndpoint), let scheme = url.scheme?.lowercased() else {
      return false
    }
    return scheme == "wss" || (allowInsecureLoopback && scheme == "ws")
  }

  public var isLocalConfigured: Bool { !normalizedExecutablePath.isEmpty }

  public var isConfigured: Bool {
    guard enabled else { return false }
    return transport == .remote ? isRemoteConfigured : isLocalConfigured
  }

  public init(
    enabled: Bool,
    transport: Transport,
    endpoint: String,
    authToken: String,
    allowInsecureLoopback: Bool,
    executablePath: String,
    arguments: [String]
  ) {
    self.enabled = enabled
    self.transport = transport
    self.endpoint = endpoint
    self.authToken = authToken
    self.allowInsecureLoopback = allowInsecureLoopback
    self.executablePath = executablePath
    self.arguments = arguments
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? defaults.enabled
    transport =
      try container.decodeIfPresent(Transport.self, forKey: .transport) ?? defaults.transport
    endpoint = try container.decodeIfPresent(String.self, forKey: .endpoint) ?? defaults.endpoint
    authToken = try container.decodeIfPresent(String.self, forKey: .authToken) ?? defaults.authToken
    allowInsecureLoopback =
      try container.decodeIfPresent(Bool.self, forKey: .allowInsecureLoopback)
      ?? defaults.allowInsecureLoopback
    executablePath =
      try container.decodeIfPresent(String.self, forKey: .executablePath) ?? defaults.executablePath
    arguments =
      try container.decodeIfPresent([String].self, forKey: .arguments) ?? defaults.arguments
  }
}

public struct AppSettings: Codable, Hashable, Sendable {
  public var defaultModelID: UUID?
  public var defaultInferenceParameters: InferenceParameters
  public var defaultSystemPrompt: String
  public var recommendedModelCatalogURLs: [String]
  public var autoCleanupCache: Bool
  public var performanceMode: PerformanceMode
  public var diagnosticsEnabled: Bool
  public var defaultOutputProtocol: OutputProtocolPreference
  public var showRawProtocolPayloads: Bool
  public var enableMCP: Bool
  public var enableSkills: Bool
  public var autonomousSkillLearningMode: AutonomousSkillLearningMode
  public var enableAgent: Bool
  public var enableLongTermMemory: Bool
  public var agentMaxIterations: Int
  public var agentMaxToolCalls: Int
  public var defaultSessionModelSource: DefaultSessionModelSource
  public var hostedResponsesAPIs: [HostedResponsesAPISettings]
  public var remoteCodeExecution: RemoteCodeExecutionSettings
  public var promptSource: PromptSourceSettings
  public var dshRuntime: DSHRuntimeSettings

  /// First hosted API entry. Mutating it updates the matching item or inserts one.
  public var hostedResponsesAPI: HostedResponsesAPISettings {
    get { hostedResponsesAPIs.first ?? .default }
    set {
      if let index = hostedResponsesAPIs.firstIndex(where: { $0.id == newValue.id }) {
        hostedResponsesAPIs[index] = newValue
      } else if hostedResponsesAPIs.isEmpty {
        hostedResponsesAPIs = [newValue]
      } else {
        hostedResponsesAPIs[0] = newValue
      }
    }
  }

  public var configuredHostedResponsesAPIs: [HostedResponsesAPISettings] {
    hostedResponsesAPIs.filter(\.isConfigured)
  }

  public func hostedResponsesAPI(id: UUID) -> HostedResponsesAPISettings? {
    hostedResponsesAPIs.first { $0.id == id }
  }

  public static let `default` = AppSettings(
    defaultModelID: nil,
    defaultInferenceParameters: .default,
    defaultSystemPrompt: PromptStore().prompt(for: .defaultSystem),
    recommendedModelCatalogURLs: [],
    autoCleanupCache: false,
    performanceMode: .balanced,
    diagnosticsEnabled: true,
    defaultOutputProtocol: .responses,
    showRawProtocolPayloads: true,
    enableMCP: true,
    enableSkills: true,
    autonomousSkillLearningMode: .autonomousPublish,
    enableAgent: true,
    enableLongTermMemory: true,
    agentMaxIterations: 16,
    agentMaxToolCalls: 32,
    defaultSessionModelSource: .localModel,
    hostedResponsesAPIs: [.default],
    remoteCodeExecution: .default,
    promptSource: .default,
    dshRuntime: .default
  )

  public init(
    defaultModelID: UUID?,
    defaultInferenceParameters: InferenceParameters,
    defaultSystemPrompt: String,
    recommendedModelCatalogURLs: [String],
    autoCleanupCache: Bool,
    performanceMode: PerformanceMode,
    diagnosticsEnabled: Bool,
    defaultOutputProtocol: OutputProtocolPreference,
    showRawProtocolPayloads: Bool,
    enableMCP: Bool,
    enableSkills: Bool,
    autonomousSkillLearningMode: AutonomousSkillLearningMode,
    enableAgent: Bool,
    enableLongTermMemory: Bool,
    agentMaxIterations: Int,
    agentMaxToolCalls: Int,
    defaultSessionModelSource: DefaultSessionModelSource,
    hostedResponsesAPIs: [HostedResponsesAPISettings],
    remoteCodeExecution: RemoteCodeExecutionSettings,
    promptSource: PromptSourceSettings,
    dshRuntime: DSHRuntimeSettings = .default
  ) {
    self.defaultModelID = defaultModelID
    self.defaultInferenceParameters = defaultInferenceParameters
    self.defaultSystemPrompt = defaultSystemPrompt
    self.recommendedModelCatalogURLs = recommendedModelCatalogURLs
    self.autoCleanupCache = autoCleanupCache
    self.performanceMode = performanceMode
    self.diagnosticsEnabled = diagnosticsEnabled
    self.defaultOutputProtocol = defaultOutputProtocol
    self.showRawProtocolPayloads = showRawProtocolPayloads
    self.enableMCP = enableMCP
    self.enableSkills = enableSkills
    self.autonomousSkillLearningMode = autonomousSkillLearningMode
    self.enableAgent = enableAgent
    self.enableLongTermMemory = enableLongTermMemory
    self.agentMaxIterations = agentMaxIterations
    self.agentMaxToolCalls = agentMaxToolCalls
    self.defaultSessionModelSource = defaultSessionModelSource
    self.hostedResponsesAPIs = hostedResponsesAPIs
    self.remoteCodeExecution = remoteCodeExecution
    self.promptSource = promptSource
    self.dshRuntime = dshRuntime
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default

    defaultModelID =
      try container.decodeIfPresent(UUID.self, forKey: .defaultModelID) ?? defaults.defaultModelID
    defaultInferenceParameters =
      try container.decodeIfPresent(InferenceParameters.self, forKey: .defaultInferenceParameters)
      ?? defaults.defaultInferenceParameters
    defaultSystemPrompt =
      try container.decodeIfPresent(String.self, forKey: .defaultSystemPrompt)
      ?? defaults.defaultSystemPrompt
    recommendedModelCatalogURLs =
      try container.decodeIfPresent([String].self, forKey: .recommendedModelCatalogURLs)
      ?? defaults.recommendedModelCatalogURLs
    autoCleanupCache =
      try container.decodeIfPresent(Bool.self, forKey: .autoCleanupCache)
      ?? defaults.autoCleanupCache
    performanceMode =
      try container.decodeIfPresent(PerformanceMode.self, forKey: .performanceMode)
      ?? defaults.performanceMode
    diagnosticsEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .diagnosticsEnabled)
      ?? defaults.diagnosticsEnabled
    defaultOutputProtocol =
      try container.decodeIfPresent(OutputProtocolPreference.self, forKey: .defaultOutputProtocol)
      ?? defaults.defaultOutputProtocol
    showRawProtocolPayloads =
      try container.decodeIfPresent(Bool.self, forKey: .showRawProtocolPayloads)
      ?? defaults.showRawProtocolPayloads
    enableMCP = try container.decodeIfPresent(Bool.self, forKey: .enableMCP) ?? defaults.enableMCP
    enableSkills =
      try container.decodeIfPresent(Bool.self, forKey: .enableSkills) ?? defaults.enableSkills
    autonomousSkillLearningMode =
      try container.decodeIfPresent(
        AutonomousSkillLearningMode.self,
        forKey: .autonomousSkillLearningMode
      ) ?? defaults.autonomousSkillLearningMode
    enableAgent =
      try container.decodeIfPresent(Bool.self, forKey: .enableAgent) ?? defaults.enableAgent
    enableLongTermMemory =
      try container.decodeIfPresent(Bool.self, forKey: .enableLongTermMemory)
      ?? defaults.enableLongTermMemory
    agentMaxIterations =
      try container.decodeIfPresent(Int.self, forKey: .agentMaxIterations)
      ?? defaults.agentMaxIterations
    agentMaxToolCalls =
      try container.decodeIfPresent(Int.self, forKey: .agentMaxToolCalls)
      ?? defaults.agentMaxToolCalls
    defaultSessionModelSource =
      try container.decodeIfPresent(
        DefaultSessionModelSource.self, forKey: .defaultSessionModelSource)
      ?? defaults.defaultSessionModelSource
    hostedResponsesAPIs = try Self.decodeHostedResponsesAPIs(from: decoder, defaults: defaults)
    remoteCodeExecution =
      try container.decodeIfPresent(RemoteCodeExecutionSettings.self, forKey: .remoteCodeExecution)
      ?? defaults.remoteCodeExecution
    promptSource =
      try container.decodeIfPresent(PromptSourceSettings.self, forKey: .promptSource)
      ?? defaults.promptSource
    dshRuntime =
      try container.decodeIfPresent(DSHRuntimeSettings.self, forKey: .dshRuntime)
      ?? defaults.dshRuntime
  }

  private enum LegacyHostedResponsesCodingKeys: String, CodingKey {
    case hostedResponsesAPI
  }

  private static func decodeHostedResponsesAPIs(
    from decoder: Decoder,
    defaults: AppSettings
  ) throws -> [HostedResponsesAPISettings] {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if let apis = try container.decodeIfPresent(
      [HostedResponsesAPISettings].self, forKey: .hostedResponsesAPIs)
    {
      return uniquedHostedResponsesAPIIds(apis)
    }

    let legacyContainer = try decoder.container(keyedBy: LegacyHostedResponsesCodingKeys.self)
    if let api = try legacyContainer.decodeIfPresent(
      HostedResponsesAPISettings.self, forKey: .hostedResponsesAPI)
    {
      return [api]
    }
    return defaults.hostedResponsesAPIs
  }

  public static func uniquedHostedResponsesAPIIds(
    _ apis: [HostedResponsesAPISettings]
  ) -> [HostedResponsesAPISettings] {
    var seen: Set<UUID> = []
    return apis.map { api in
      var copy = api
      if seen.contains(copy.id) {
        copy.id = UUID()
      }
      seen.insert(copy.id)
      return copy
    }
  }
}
