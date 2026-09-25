import Foundation
import iCordisKernel

public enum PromptKey: String, CaseIterable, Sendable {
  case defaultSystem = "default-system"
  case memorySafety = "memory-safety"
  /// Native tool-calling contract. The default for models that support it.
  case agentSystemNative = "agent-system-native"
  /// JSON-in-prose contract, retained for local models without tool calling.
  case agentSystem = "agent-system"
  case agentCompletionDecision = "agent-completion-decision"
  case agentContextCompress = "agent-context-compress"
  case agentRunStop = "agent-run-stop"
  case agentTaskIntent = "agent-task-intent"
  case titleGeneration = "title-generation"
  case systemRuntimeContext = "system-runtime-context"
  case liteRTCapabilityGuide = "litert-capability-guide"

  public var fileName: String {
    "\(rawValue).md"
  }
}

public struct PromptTemplate: Sendable, Hashable {
  public var text: String

  public func rendered(replacements: [String: String]) -> String {
    replacements.reduce(text) { partial, replacement in
      partial.replacingOccurrences(of: "{{\(replacement.key)}}", with: replacement.value)
    }
  }

  public init(text: String) { self.text = text }
}

public struct SystemPromptRuntimeContext: Sendable, Hashable {
  public var date: Date
  public var timeZone: TimeZone
  public var platform: String
  public var workingDirectoryPath: String?

  public init(
    date: Date = .now,
    timeZone: TimeZone = .current,
    platform: String = Self.currentPlatform,
    workingDirectoryPath: String? = nil
  ) {
    self.date = date
    self.timeZone = timeZone
    self.platform = platform
    self.workingDirectoryPath = workingDirectoryPath
  }

  public var rendered: String {
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds, .withTimeZone]
    formatter.timeZone = timeZone

    return PromptStore().template(for: .systemRuntimeContext).rendered(replacements: [
      "currentDateTime": formatter.string(from: date),
      "timeZone": timeZone.identifier,
      "platform": platform,
      "workingDirectory": workingDirectoryPath ?? "None selected",
    ])
  }

  public static var currentPlatform: String {
    #if os(macOS)
      return "macOS"
    #elseif os(iOS)
      return "iOS"
    #elseif os(tvOS)
      return "tvOS"
    #elseif os(watchOS)
      return "watchOS"
    #elseif os(visionOS)
      return "visionOS"
    #else
      return "Unknown Apple platform"
    #endif
  }
}

public struct SystemPromptComposer: Sendable {
  public func compose(
    basePrompt: String,
    sessionPrompt: String? = nil,
    runtimeContext: SystemPromptRuntimeContext? = nil
  ) -> String {
    [basePrompt, sessionPrompt, runtimeContext?.rendered]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      .joined(separator: "\n\n")
  }

  public init() {}
}

public struct PromptSourceSettings: Codable, Hashable, Sendable {
  public var remoteBaseURL: String
  public var apiKey: String
  public var prefersRemote: Bool

  public static let `default` = PromptSourceSettings(
    remoteBaseURL: "",
    apiKey: "",
    prefersRemote: false
  )

  public var normalizedRemoteBaseURL: String {
    remoteBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var normalizedAPIKey: String {
    apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
  }

  public var isRemoteConfigured: Bool {
    !normalizedRemoteBaseURL.isEmpty && URL(string: normalizedRemoteBaseURL) != nil
  }

  public init(remoteBaseURL: String, apiKey: String, prefersRemote: Bool) {
    self.remoteBaseURL = remoteBaseURL
    self.apiKey = apiKey
    self.prefersRemote = prefersRemote
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    remoteBaseURL =
      try container.decodeIfPresent(String.self, forKey: .remoteBaseURL) ?? defaults.remoteBaseURL
    apiKey = try container.decodeIfPresent(String.self, forKey: .apiKey) ?? defaults.apiKey
    prefersRemote =
      try container.decodeIfPresent(Bool.self, forKey: .prefersRemote) ?? defaults.prefersRemote
  }
}

public struct PromptStore: Sendable {
  private static let promptsDirectoryName = "Prompts"
  private let currentDirectoryURL: URL
  private let bundle: Bundle

  public init(fileManager: FileManager = .default, bundle: Bundle? = nil) {
    self.currentDirectoryURL = URL(
      fileURLWithPath: fileManager.currentDirectoryPath,
      isDirectory: true
    )
    self.bundle = bundle ?? .module
  }

  public func prompt(for key: PromptKey) -> String {
    template(for: key).text
  }

  public func template(for key: PromptKey) -> PromptTemplate {
    guard let prompt = localPrompt(for: key) else {
      preconditionFailure("Missing required prompt resource: \(key.fileName)")
    }
    return PromptTemplate(text: prompt)
  }

  public func fetchRemotePrompt(
    for key: PromptKey,
    settings: PromptSourceSettings,
    session: URLSession = .shared
  ) async throws -> String {
    guard settings.isRemoteConfigured else {
      throw ValidationError.invalidConfiguration("Prompt remoteBaseURL is not configured.")
    }

    let baseURL = URL(string: settings.normalizedRemoteBaseURL)!
    let url = baseURL.appending(path: key.fileName)
    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 20
    if !settings.normalizedAPIKey.isEmpty {
      request.setValue("Bearer \(settings.normalizedAPIKey)", forHTTPHeaderField: "Authorization")
    }

    let (data, response) = try await session.data(for: request)
    guard let httpResponse = response as? HTTPURLResponse else {
      throw InferenceError.runtimeFailure("Prompt server returned an invalid response.")
    }
    guard (200..<300).contains(httpResponse.statusCode) else {
      throw InferenceError.runtimeFailure(
        "Prompt server returned HTTP \(httpResponse.statusCode) for \(url.absoluteString).")
    }
    guard let text = String(data: data, encoding: .utf8),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else {
      throw InferenceError.runtimeFailure(
        "Prompt server returned an empty prompt for \(key.fileName).")
    }
    return text
  }

  private func localPrompt(for key: PromptKey) -> String? {
    candidateLocalPromptURLs(for: key).lazy.compactMap { url in
      try? String(contentsOf: url, encoding: .utf8)
    }.first
  }

  private func candidateLocalPromptURLs(for key: PromptKey) -> [URL] {
    var urls: [URL] = []
    urls.append(
      currentDirectoryURL.appending(path: Self.promptsDirectoryName).appending(path: key.fileName))
    urls.append(
      currentDirectoryURL.deletingLastPathComponent().appending(path: Self.promptsDirectoryName)
        .appending(path: key.fileName))

    if let bundleURL = bundle.url(
      forResource: key.rawValue,
      withExtension: "md",
      subdirectory: Self.promptsDirectoryName
    ) {
      urls.append(bundleURL)
    }
    if let bundleURL = bundle.url(forResource: key.rawValue, withExtension: "md") {
      urls.append(bundleURL)
    }
    return urls
  }

}
