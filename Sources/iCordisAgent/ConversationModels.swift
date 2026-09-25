import Foundation
import iCordisKernel

public struct GenerationMetadata: Codable, Hashable, Sendable {
  public var modelID: UUID?
  public var duration: TimeInterval?
  public var usage: Usage?

  public init(modelID: UUID? = nil, duration: TimeInterval? = nil, usage: Usage? = nil) {
    self.modelID = modelID
    self.duration = duration
    self.usage = usage
  }
}

public struct ConversationItem: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var role: ChatRole
  public var content: [ContentPart]
  public var createdAt: Date
  public var status: MessageStatus
  public var tokenCount: Int?
  public var generationMetadata: GenerationMetadata?
  public var protocolMetadata: [String: JSONValue]
  public var invocationMetadata: [String: JSONValue]

  public init(
    id: UUID = UUID(),
    role: ChatRole,
    content: [ContentPart],
    createdAt: Date = .now,
    status: MessageStatus = .completed,
    tokenCount: Int? = nil,
    generationMetadata: GenerationMetadata? = nil,
    protocolMetadata: [String: JSONValue] = [:],
    invocationMetadata: [String: JSONValue] = [:]
  ) {
    self.id = id
    self.role = role
    self.content = content
    self.createdAt = createdAt
    self.status = status
    self.tokenCount = tokenCount
    self.generationMetadata = generationMetadata
    self.protocolMetadata = protocolMetadata
    self.invocationMetadata = invocationMetadata
  }

  public var plainText: String {
    content
      .filter { !$0.kind.isMedia }
      .compactMap(\.text)
      .joined()
  }

  public var attachmentParts: [ContentPart] {
    content.filter { $0.kind == .imageFile }
  }

  public var audioAttachmentParts: [ContentPart] {
    content.filter { $0.kind == .audioFile }
  }

  public var videoAttachmentParts: [ContentPart] {
    content.filter { $0.kind == .videoFile }
  }

  public var mediaAttachmentParts: [ContentPart] {
    content.filter { $0.kind.isMedia }
  }

  public var contextTokenEstimate: Int {
    content.reduce(0) { $0 + $1.contextTokenEstimate }
  }

  public var excludesFromPrompt: Bool {
    if case .bool(true)? = protocolMetadata["prompt_excluded"] {
      return true
    }
    return false
  }

  public var isTimelineEvent: Bool {
    if case .bool(true)? = protocolMetadata["timeline_event"] {
      return true
    }
    return false
  }

  public var timelineTitle: String? {
    protocolMetadata["timeline_title"]?.stringValue
  }
}

extension ContentPart.Kind {
  public var isMedia: Bool {
    switch self {
    case .imageFile, .audioFile, .videoFile:
      return true
    case .text, .code, .structured, .capabilityReference:
      return false
    }
  }
}

public struct ConversationWorkingDirectory: Codable, Hashable, Sendable {
  public var path: String
  public var bookmarkData: Data?

  public init(path: String, bookmarkData: Data? = nil) {
    self.path = URL(fileURLWithPath: path).standardizedFileURL.path
    self.bookmarkData = bookmarkData
  }

  public init(url: URL, bookmarkData: Data? = nil) {
    self.init(path: url.path, bookmarkData: bookmarkData)
  }

  /// Captures persistent access granted by a native document picker. Bookmark
  /// creation is best-effort because non-sandboxed and test URLs do not always
  /// support security-scoped bookmark options.
  public init(securityScopedURL url: URL) {
    let standardizedURL = url.standardizedFileURL
    let isAccessing = standardizedURL.startAccessingSecurityScopedResource()
    defer {
      if isAccessing {
        standardizedURL.stopAccessingSecurityScopedResource()
      }
    }
    #if os(macOS)
      let bookmarkOptions: URL.BookmarkCreationOptions = [.withSecurityScope]
    #else
      let bookmarkOptions: URL.BookmarkCreationOptions = []
    #endif
    let bookmarkData = try? standardizedURL.bookmarkData(
      options: bookmarkOptions,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    self.init(url: standardizedURL, bookmarkData: bookmarkData)
  }

  public var displayName: String {
    URL(fileURLWithPath: path).lastPathComponent
  }

  public func resolvedURL() -> URL {
    guard let bookmarkData else {
      return URL(fileURLWithPath: path).standardizedFileURL
    }
    var isStale = false
    #if os(macOS)
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
      let options: URL.BookmarkResolutionOptions = []
    #endif
    if let url = try? URL(
      resolvingBookmarkData: bookmarkData,
      options: options,
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ) {
      return url.standardizedFileURL
    }
    return URL(fileURLWithPath: path).standardizedFileURL
  }
}

public struct ConversationSession: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var title: String
  public var createdAt: Date
  public var updatedAt: Date
  public var selectedModelID: UUID?
  public var workingDirectory: ConversationWorkingDirectory?
  public var systemPrompt: String
  public var parameters: InferenceParameters
  public var isAgentModeEnabled: Bool
  public var protocolMetadata: [String: JSONValue]
  public var items: [ConversationItem]
  public var traces: [CapabilityExecutionTrace]

  public init(
    id: UUID,
    title: String,
    createdAt: Date,
    updatedAt: Date,
    selectedModelID: UUID?,
    workingDirectory: ConversationWorkingDirectory? = nil,
    systemPrompt: String,
    parameters: InferenceParameters,
    isAgentModeEnabled: Bool = false,
    protocolMetadata: [String: JSONValue] = [:],
    items: [ConversationItem],
    traces: [CapabilityExecutionTrace]
  ) {
    self.id = id
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.selectedModelID = selectedModelID
    self.workingDirectory = workingDirectory
    self.systemPrompt = systemPrompt
    self.parameters = parameters
    self.isAgentModeEnabled = isAgentModeEnabled
    self.protocolMetadata = protocolMetadata
    self.items = items
    self.traces = traces
  }

  public static func draft(defaults: AppSettings) -> ConversationSession {
    return ConversationSession(
      id: UUID(),
      title: "New Conversation",
      createdAt: .now,
      updatedAt: .now,
      selectedModelID: nil,
      workingDirectory: nil,
      systemPrompt: defaults.defaultSystemPrompt,
      parameters: defaults.defaultInferenceParameters,
      isAgentModeEnabled: true,
      protocolMetadata: [:],
      items: [],
      traces: []
    )
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    title = try container.decode(String.self, forKey: .title)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
    selectedModelID = try container.decodeIfPresent(UUID.self, forKey: .selectedModelID)
    workingDirectory = try container.decodeIfPresent(
      ConversationWorkingDirectory.self, forKey: .workingDirectory)
    systemPrompt = try container.decode(String.self, forKey: .systemPrompt)
    parameters = try container.decode(InferenceParameters.self, forKey: .parameters)
    isAgentModeEnabled =
      try container.decodeIfPresent(Bool.self, forKey: .isAgentModeEnabled) ?? false
    protocolMetadata =
      try container.decodeIfPresent([String: JSONValue].self, forKey: .protocolMetadata) ?? [:]
    items = try container.decode([ConversationItem].self, forKey: .items)
    traces = try container.decode([CapabilityExecutionTrace].self, forKey: .traces)
  }

  public mutating func touch() {
    updatedAt = .now
  }
}

public struct PromptEnvelope: Sendable, Hashable {
  public var messages: [ConversationItem]
  public var contextTokenEstimate: Int
  public var sessionID: UUID?
  public var capabilityDescriptors: [CapabilityDescriptor]

  public init(
    messages: [ConversationItem],
    contextTokenEstimate: Int,
    sessionID: UUID? = nil,
    capabilityDescriptors: [CapabilityDescriptor] = []
  ) {
    self.messages = messages
    self.contextTokenEstimate = contextTokenEstimate
    self.sessionID = sessionID
    self.capabilityDescriptors = capabilityDescriptors
  }
}

extension AppSettings {
  public var preferredSessionModelID: UUID? {
    switch defaultSessionModelSource {
    case .hostedAPI:
      if let defaultModelID,
        hostedResponsesAPIs.contains(where: { $0.id == defaultModelID && $0.isConfigured })
      {
        return defaultModelID
      }
      return configuredHostedResponsesAPIs.first?.id ?? defaultModelID
    case .localModel:
      if let defaultModelID, HostedResponsesModel.contains(defaultModelID, in: self) {
        return nil
      }
      return defaultModelID
    }
  }
}

public struct PromptBuilder: Sendable {
  private let promptStore = PromptStore()
  private let systemPromptComposer = SystemPromptComposer()

  public func buildPrompt(
    for session: ConversationSession,
    newUserText: String,
    maxHistoryMessages: Int = 20,
    memoryContext: LongTermMemoryContext? = nil
  ) -> PromptEnvelope {
    buildPrompt(
      for: session,
      newUserContent: [.text(newUserText)],
      maxHistoryMessages: maxHistoryMessages,
      memoryContext: memoryContext
    )
  }

  public func buildPrompt(
    for session: ConversationSession,
    newUserContent: [ContentPart],
    maxHistoryMessages: Int = 20,
    memoryContext: LongTermMemoryContext? = nil
  ) -> PromptEnvelope {
    let runtimeContext = SystemPromptRuntimeContext(
      workingDirectoryPath: session.workingDirectory?.path
    )
    let systemItem = ConversationItem(
      role: .system,
      content: [
        .text(
          systemPromptComposer.compose(
            basePrompt: promptStore.prompt(for: .memorySafety),
            sessionPrompt: session.systemPrompt,
            runtimeContext: runtimeContext
          ))
      ],
      status: .completed
    )
    let history = Array(
      session.items
        .filter { !$0.excludesFromPrompt && $0.role != .system }
        .suffix(maxHistoryMessages)
    )
    let userItem = ConversationItem(
      role: .user,
      content: newUserContent,
      status: .completed
    )
    let memoryItems: [ConversationItem]
    if let memoryContext, !memoryContext.rendered.isEmpty {
      memoryItems = [
        ConversationItem(
          role: .user,
          content: [.text(memoryContext.rendered)],
          status: .completed,
          protocolMetadata: ["william.context.kind": .string("long_term_memory")]
        )
      ]
    } else {
      memoryItems = []
    }
    let messages = [systemItem] + memoryItems + history + [userItem]
    let estimate = messages.reduce(0) { $0 + $1.contextTokenEstimate }
    return PromptEnvelope(messages: messages, contextTokenEstimate: estimate)
  }

  public init() {}
}
