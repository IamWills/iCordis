import Foundation
import iCordisKernel

public enum HostedResponsesModel {
  public static let configuredModelID = HostedResponsesAPISettings.legacyModelID

  /// `hosted.protocol` metadata tag that routes a configured model to the
  /// chat-completions runtime instead of the ResponsesAI envelope backend.
  /// Kept in one place so the descriptor and the runtime router agree.
  public static let chatCompletionsProtocolTag = "openai-chat-completions"

  public static func isChatCompletions(_ model: LocalModelDescriptor) -> Bool {
    model.metadata["hosted.protocol"]?.stringValue == chatCompletionsProtocolTag
  }

  public static func descriptors(from settings: AppSettings) -> [LocalModelDescriptor] {
    let configured = settings.configuredHostedResponsesAPIs
    return configured.compactMap { configuration in
      descriptor(
        from: configuration,
        defaultModelID: settings.defaultModelID,
        siblings: configured
      )
    }
  }

  public static func descriptor(from settings: AppSettings) -> LocalModelDescriptor? {
    descriptors(from: settings).first
  }

  public static func descriptor(
    from configuration: HostedResponsesAPISettings,
    defaultModelID: UUID?,
    siblings: [HostedResponsesAPISettings] = []
  ) -> LocalModelDescriptor? {
    guard configuration.isConfigured else {
      return nil
    }

    let now = Date()
    let isChat = configuration.apiProtocol == .openAIChatCompletions
    // Chat-completions endpoints call the bare model (e.g. `deepseek-chat`);
    // the ResponsesAI envelope calls the `Company:Model` composite.
    let modelName =
      isChat
      ? (configuration.normalizedModel.isEmpty
        ? configuration.resolvedModelName : configuration.normalizedModel)
      : configuration.resolvedModelName
    return LocalModelDescriptor(
      id: configuration.id,
      displayName: displayName(for: configuration, among: siblings),
      origin: .configured,
      // Chat-completions models keep the `.responsesAPI` format so they
      // inherit all hosted-model treatment (no local download, ready,
      // native tool calling); the runtime router distinguishes them by the
      // `hosted.protocol` tag, not by a separate ModelFormat case.
      format: .responsesAPI,
      modality: .text,
      path: configuration.normalizedBaseURL,
      sizeInBytes: 0,
      quantization: nil,
      companionFiles: [],
      metadata: [
        "hosted.id": .string(configuration.id.uuidString),
        "hosted.provider": .string(configuration.backendLabel),
        "hosted.company": .string(configuration.normalizedCompany),
        "hosted.base_url": .string(configuration.normalizedBaseURL),
        "hosted.model": .string(modelName),
        "hosted.api_key_configured": .bool(!configuration.normalizedAPIKey.isEmpty),
        "hosted.protocol": .string(
          isChat ? chatCompletionsProtocolTag : "responses-envelope-openai"),
      ],
      compatibility: ModelCompatibility(
        state: .compatible,
        notes: isChat ? "OpenAI-compatible chat completions model" : "Hosted Responses API model"
      ),
      isDefault: defaultModelID == configuration.id,
      isCached: false,
      isLoaded: false,
      createdAt: now,
      updatedAt: now
    )
  }

  public static func configuration(
    from settings: AppSettings,
    matching model: LocalModelDescriptor
  ) -> HostedResponsesAPISettings? {
    if let exact = settings.hostedResponsesAPI(id: model.id), exact.isConfigured {
      return exact
    }

    let url = model.metadata["hosted.base_url"]?.stringValue ?? model.path
    let name = model.metadata["hosted.model"]?.stringValue ?? model.displayName
    if let match = settings.configuredHostedResponsesAPIs.first(where: {
      $0.normalizedBaseURL == url && $0.resolvedModelName == name
    }) {
      return match
    }

    let configured = settings.configuredHostedResponsesAPIs
    return configured.count == 1 ? configured.first : nil
  }

  public static func contains(_ id: UUID, in settings: AppSettings) -> Bool {
    settings.hostedResponsesAPIs.contains { $0.id == id }
  }

  private static func displayName(
    for configuration: HostedResponsesAPISettings,
    among siblings: [HostedResponsesAPISettings]
  ) -> String {
    let model = configuration.resolvedModelName
    let duplicateCount = siblings.filter { $0.resolvedModelName == model }.count
    guard duplicateCount > 1 else {
      return model
    }
    let host =
      URL(string: configuration.normalizedBaseURL)?.host
      ?? configuration.normalizedBaseURL
    return host.isEmpty ? model : "\(model) · \(host)"
  }
}
