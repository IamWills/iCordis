import Foundation
import iCordisKernel

public enum RegisteredAppKind: String, Codable, CaseIterable, Sendable {
  case staticHTML
  case script
  case webService

  public var displayName: String {
    switch self {
    case .staticHTML: "Static HTML"
    case .script: "Script"
    case .webService: "Web Service"
    }
  }
}

public struct RegisteredAppLaunchConfiguration: Codable, Hashable, Sendable {
  public static let entryPlaceholder = "{{entry}}"
  public static let rootPlaceholder = "{{root}}"

  public var command: String
  public var arguments: [String]
  public var environment: [String: String]
  public var workingDirectory: String
  public var contentURL: String?
  public var timeoutSeconds: TimeInterval

  public init(
    command: String,
    arguments: [String] = [Self.entryPlaceholder],
    environment: [String: String] = [:],
    workingDirectory: String = ".",
    contentURL: String? = nil,
    timeoutSeconds: TimeInterval = 3_600
  ) {
    self.command = command
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.contentURL = contentURL
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct RegisteredAppManifest: Codable, Hashable, Sendable {
  public var name: String
  public var kind: RegisteredAppKind
  public var entry: String
  public var command: String?
  public var arguments: [String]?
  public var environment: [String: String]?
  public var workingDirectory: String?
  public var contentURL: String?
  public var timeoutSeconds: TimeInterval?

  public init(
    name: String, kind: RegisteredAppKind, entry: String, command: String? = nil,
    arguments: [String]? = nil, environment: [String: String]? = nil,
    workingDirectory: String? = nil, contentURL: String? = nil, timeoutSeconds: TimeInterval? = nil
  ) {
    self.name = name
    self.kind = kind
    self.entry = entry
    self.command = command
    self.arguments = arguments
    self.environment = environment
    self.workingDirectory = workingDirectory
    self.contentURL = contentURL
    self.timeoutSeconds = timeoutSeconds
  }
}

public struct RegisteredAppRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var displayName: String
  public var kind: RegisteredAppKind
  public var entryPath: String
  public var rootPath: String
  public var bookmarkData: Data?
  public var bookmarkRootPath: String?
  public var sourceSessionID: UUID?
  public var launchConfiguration: RegisteredAppLaunchConfiguration?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID = UUID(),
    displayName: String,
    kind: RegisteredAppKind = .staticHTML,
    entryPath: String,
    rootPath: String,
    bookmarkData: Data? = nil,
    bookmarkRootPath: String? = nil,
    sourceSessionID: UUID? = nil,
    launchConfiguration: RegisteredAppLaunchConfiguration? = nil,
    createdAt: Date = .now,
    updatedAt: Date = .now
  ) {
    self.id = id
    self.displayName = displayName
    self.kind = kind
    self.entryPath = URL(fileURLWithPath: entryPath).standardizedFileURL.path
    self.rootPath = URL(fileURLWithPath: rootPath).standardizedFileURL.path
    self.bookmarkData = bookmarkData
    self.bookmarkRootPath = bookmarkRootPath.map {
      URL(fileURLWithPath: $0).standardizedFileURL.path
    }
    self.sourceSessionID = sourceSessionID
    self.launchConfiguration = launchConfiguration
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public var resolvedRootURL: URL {
    let storedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL
    guard let resolvedBookmarkRoot,
      let bookmarkRootPath
    else { return storedRoot }
    let storedBookmarkRoot = URL(fileURLWithPath: bookmarkRootPath).standardizedFileURL
    guard storedRoot.path != storedBookmarkRoot.path else { return resolvedBookmarkRoot }
    let prefix =
      storedBookmarkRoot.path.hasSuffix("/")
      ? storedBookmarkRoot.path : storedBookmarkRoot.path + "/"
    guard storedRoot.path.hasPrefix(prefix) else { return storedRoot }
    return
      resolvedBookmarkRoot
      .appendingPathComponent(String(storedRoot.path.dropFirst(prefix.count)))
      .standardizedFileURL
  }

  public var resolvedEntryURL: URL {
    let storedRoot = URL(fileURLWithPath: rootPath).standardizedFileURL
    let storedEntry = URL(fileURLWithPath: entryPath).standardizedFileURL
    if let bookmarkRootPath,
      storedEntry.path == URL(fileURLWithPath: bookmarkRootPath).standardizedFileURL.path,
      let resolvedBookmarkRoot
    {
      return resolvedBookmarkRoot
    }
    guard storedEntry.path != storedRoot.path else { return resolvedRootURL }
    let prefix = storedRoot.path.hasSuffix("/") ? storedRoot.path : storedRoot.path + "/"
    guard storedEntry.path.hasPrefix(prefix) else { return storedEntry }
    let relativePath = String(storedEntry.path.dropFirst(prefix.count))
    return resolvedRootURL.appendingPathComponent(relativePath).standardizedFileURL
  }

  public var isAvailable: Bool {
    FileManager.default.fileExists(atPath: resolvedEntryURL.path)
  }

  private var resolvedBookmarkRoot: URL? {
    guard let bookmarkData else { return nil }
    var isStale = false
    #if os(macOS)
      let options: URL.BookmarkResolutionOptions = [.withSecurityScope]
    #else
      let options: URL.BookmarkResolutionOptions = []
    #endif
    return try? URL(
      resolvingBookmarkData: bookmarkData,
      options: options,
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    ).standardizedFileURL
  }
}
