import Foundation
import iCordisKernel

/// User-visible sentences the loop writes into the transcript.
/// Mount `RuntimeServices.transcriptCopy` to replace them. The loop's own
/// default is `AgentCopyService.neutral`, which does not name a product.
public enum AgentTranscriptMoment: Sendable, Hashable {
  /// The provider failed twice. `completedTools` are the tools that succeeded.
  case providerFailure(detail: String, completedTools: [String])
  /// The user declined to continue after the output-token limit.
  case outputLimitStopped
}

public struct AgentCopyService: WilliamService {
  public let render: @Sendable (AgentTranscriptMoment) -> String

  public init(render: @escaping @Sendable (AgentTranscriptMoment) -> String) {
    self.render = render
  }

  public static let neutral = AgentCopyService { moment in
    switch moment {
    case .providerFailure(let detail, let tools):
      let completed =
        tools.isEmpty
        ? "本次运行尚未完成任何工具操作。"
        : "已完成并保留的操作：\n" + tools.map { "- \($0)" }.joined(separator: "\n")
      return """
        与模型服务的连接连续失败，运行已停止：\(detail)

        \(completed)

        文件改动均已保留。可以直接要求继续，或指出希望优先完成的部分。
        """
    case .outputLimitStopped:
      return "已按你的选择停止继续生成。当前任务尚未完成；已完成的工具操作和文件改动均已保留，你可以稍后要求继续。"
    }
  }

  /// William-compatible voice. Mount `WilliamTranscriptCopyPlugin` to opt in.
  public static let william = AgentCopyService { moment in
    switch moment {
    case .providerFailure(let detail, let tools):
      let completed =
        tools.isEmpty
        ? "本次运行尚未完成任何工具操作。"
        : "已完成并保留的操作：\n" + tools.map { "- \($0)" }.joined(separator: "\n")
      return """
        与模型服务的连接连续失败，运行已停止：\(detail)

        \(completed)

        文件改动均已保留。可以直接让 William 继续，或指出希望优先完成的部分。
        """
    case .outputLimitStopped:
      return "已按你的选择停止继续生成。当前任务尚未完成；已完成的工具操作和文件改动均已保留，你可以稍后要求 William 继续。"
    }
  }
}

public struct NeutralTranscriptCopyPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("icordis.transcript-copy.neutral"),
    name: "Neutral Transcript Copy",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent.transcript-copy")],
    providedServices: [RuntimeServices.transcriptCopy.id]
  )

  public func apply(to context: PluginContext) async throws {
    try await context.provide(AgentCopyService.neutral, as: RuntimeServices.transcriptCopy)
  }

  public init() {}
}

public struct WilliamTranscriptCopyPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.transcript-copy"),
    name: "William Transcript Copy",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent.transcript-copy")],
    providedServices: [RuntimeServices.transcriptCopy.id]
  )

  public func apply(to context: PluginContext) async throws {
    try await context.provide(AgentCopyService.william, as: RuntimeServices.transcriptCopy)
  }

  public init() {}
}

/// How chain-of-thought leaves the loop.
///
/// `.typedEvent` emits `StreamEvent.reasoningDelta` and does not write the
/// thinking text into the answer channel. `.transcriptMarkers` also folds the
/// same deltas into the text channel between `open` and `close`, for hosts
/// whose UI only scans transcript text.
public struct ReasoningPresentation: Sendable, Hashable {
  public enum Style: Sendable, Hashable {
    case typedEvent
    case transcriptMarkers(open: String, close: String)
  }

  public var style: Style

  public init(style: Style) {
    self.style = style
  }

  public static let typedEvent = ReasoningPresentation(style: .typedEvent)

  public static let williamTranscript = ReasoningPresentation(
    style: .transcriptMarkers(open: "<reasoning>\n", close: "\n</reasoning>")
  )
}

public struct ReasoningPresentationService: WilliamService {
  public let presentation: ReasoningPresentation

  public init(presentation: ReasoningPresentation) {
    self.presentation = presentation
  }

  public static let typedEvent = ReasoningPresentationService(presentation: .typedEvent)
  public static let williamTranscript = ReasoningPresentationService(
    presentation: .williamTranscript)
}

public struct TypedReasoningPresentationPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("icordis.reasoning-presentation.typed"),
    name: "Typed Reasoning Presentation",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent.reasoning")],
    providedServices: [RuntimeServices.reasoningPresentation.id]
  )

  public func apply(to context: PluginContext) async throws {
    try await context.provide(
      ReasoningPresentationService.typedEvent, as: RuntimeServices.reasoningPresentation)
  }

  public init() {}
}

public struct WilliamReasoningTranscriptPlugin: WilliamPlugin {
  public static let manifest = PluginManifest(
    id: PluginID("william.reasoning-transcript"),
    name: "William Reasoning Transcript",
    version: SemanticVersion(1),
    capabilities: [PluginCapability("agent.reasoning")],
    providedServices: [RuntimeServices.reasoningPresentation.id]
  )

  public func apply(to context: PluginContext) async throws {
    try await context.provide(
      ReasoningPresentationService.williamTranscript, as: RuntimeServices.reasoningPresentation)
  }

  public init() {}
}
