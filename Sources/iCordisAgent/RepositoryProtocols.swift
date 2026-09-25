import Foundation
import iCordisKernel

public protocol SessionRepositoryProtocol: Sendable {
  func listSessions() async throws -> [ConversationSession]
  func loadSession(id: UUID) async throws -> ConversationSession
  func saveSession(_ session: ConversationSession) async throws
  func deleteSession(id: UUID) async throws
}

public protocol LongTermMemoryRepositoryProtocol: Sendable {
  func listMemories() async throws -> [LongTermMemoryRecord]
  func loadMemory(id: UUID) async throws -> LongTermMemoryRecord
  func saveMemory(_ memory: LongTermMemoryRecord) async throws
  func deleteMemory(id: UUID) async throws
}

public protocol ResponseConversationHistoryRepositoryProtocol: Sendable {
  func conversationID(for sessionID: UUID) async throws -> String?
  func bindConversationID(_ conversationID: String, to sessionID: UUID, modelID: UUID?) async throws
  func appendEvent(_ event: ResponseConversationEventRecord) async throws
  func events(conversationID: String) async throws -> [ResponseConversationEventRecord]
}

public protocol SettingsRepositoryProtocol: Sendable {
  func loadSettings() async throws -> AppSettings
  func saveSettings(_ settings: AppSettings) async throws
}

public protocol ModelRepositoryProtocol: Sendable {
  func listModels() async throws -> [LocalModelDescriptor]
  func saveModel(_ descriptor: LocalModelDescriptor) async throws
  func deleteModel(id: UUID) async throws
  func loadModel(id: UUID) async throws -> LocalModelDescriptor
}

public protocol ModelDownloadRepositoryProtocol: Sendable {
  func listDownloads() async throws -> [ModelDownloadRecord]
  func saveDownload(_ record: ModelDownloadRecord) async throws
  func deleteDownload(id: UUID) async throws
  func loadDownload(id: UUID) async throws -> ModelDownloadRecord
}

public protocol CodeWorkspaceRepositoryProtocol: Sendable {
  func listWorkspaces() async throws -> [CodeWorkspaceRecord]
  func loadWorkspace(id: UUID) async throws -> CodeWorkspaceRecord
  func saveWorkspace(_ workspace: CodeWorkspaceRecord) async throws
  func deleteWorkspace(id: UUID) async throws
}

public protocol RegisteredAppRepositoryProtocol: Sendable {
  func listApps() async throws -> [RegisteredAppRecord]
  func loadApp(id: UUID) async throws -> RegisteredAppRecord
  func saveApp(_ app: RegisteredAppRecord) async throws
  func deleteApp(id: UUID) async throws
}

public protocol InferenceRuntimeProtocol: Sendable {
  func activeModelID() async -> UUID?
  func loadModel(_ model: LocalModelDescriptor) async throws
  func unloadModel() async
  func generate(request: AIRequest) async throws -> AsyncThrowingStream<StreamEvent, Error>
  func cancelGeneration(sessionID: UUID) async
}

public protocol CapabilityInvoking: Sendable {
  func executeCapability(
    _ request: CapabilityInvocationRequest,
    settings: AppSettings
  ) async throws -> CapabilityExecutionTrace
}
