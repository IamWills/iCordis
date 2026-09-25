import Foundation
import iCordisKernel

public enum CodeWorkspacePlatformAvailability: String, Codable, CaseIterable, Sendable {
  case local
  case remoteOnly
  case unavailable
}

public enum CodeWorkspaceKind: String, Codable, CaseIterable, Sendable {
  case generic
  case git
  case swiftPackage
  case xcodeProject
}

public struct CodeWorkspaceRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var displayName: String
  public var localPath: String?
  public var bookmarkData: Data?
  public var remoteURL: String?
  public var defaultBranch: String?
  public var kind: CodeWorkspaceKind
  public var platformAvailability: CodeWorkspacePlatformAvailability
  public var languageHints: [String]
  public var metadata: [String: JSONValue]
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    displayName: String,
    localPath: String? = nil,
    bookmarkData: Data? = nil,
    remoteURL: String? = nil,
    defaultBranch: String? = nil,
    kind: CodeWorkspaceKind = .generic,
    platformAvailability: CodeWorkspacePlatformAvailability = .unavailable,
    languageHints: [String] = [],
    metadata: [String: JSONValue] = [:],
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.displayName = displayName
    self.localPath = localPath.map { URL(fileURLWithPath: $0).standardizedFileURL.path }
    self.bookmarkData = bookmarkData
    self.remoteURL = remoteURL
    self.defaultBranch = defaultBranch
    self.kind = kind
    self.platformAvailability = platformAvailability
    self.languageHints = languageHints
    self.metadata = metadata
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public mutating func touch() {
    updatedAt = .now
  }

  public var resolvedLocalURL: URL? {
    guard let localPath else { return nil }
    guard let bookmarkData else {
      return URL(fileURLWithPath: localPath).standardizedFileURL
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
    return URL(fileURLWithPath: localPath).standardizedFileURL
  }
}

public struct CodeWorkspaceSummary: Codable, Hashable, Sendable {
  public var id: UUID
  public var displayName: String
  public var localPath: String?
  public var remoteURL: String?
  public var kind: CodeWorkspaceKind
  public var platformAvailability: CodeWorkspacePlatformAvailability
  public var languageHints: [String]
  public var updatedAt: Date

  public init(record: CodeWorkspaceRecord) {
    id = record.id
    displayName = record.displayName
    localPath = record.localPath
    remoteURL = record.remoteURL
    kind = record.kind
    platformAvailability = record.platformAvailability
    languageHints = record.languageHints
    updatedAt = record.updatedAt
  }
}
