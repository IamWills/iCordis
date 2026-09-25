import Foundation
import iCordisKernel

public enum RuntimeActivityState: String, Codable, CaseIterable, Sendable {
  case idle
  case loading
  case generating
  case invokingCapability
  case error
}

public enum PerformanceMode: String, Codable, CaseIterable, Sendable {
  case efficiency
  case balanced
  case highPerformance
}

public struct InferenceParameters: Codable, Hashable, Sendable {
  public var temperature: Double
  public var topP: Double
  public var topK: Int
  public var maxTokens: Int
  public var repetitionPenalty: Double
  public var seed: Int?
  public var contextWindow: Int
  public var stream: Bool

  /// On-device GGUF/MLX backends clamp KV allocation to this cap so the
  /// hosted 500K default cannot OOM a local model.
  public static let localBackendContextWindowCap = 32_768
  /// Previous product default. Sessions and settings that still persist this
  /// value are upgraded to `default.contextWindow` on decode.
  public static let legacyDefaultContextWindow = 8192

  public static let `default` = InferenceParameters(
    temperature: 0.7,
    topP: 0.9,
    topK: 40,
    maxTokens: 1024,
    repetitionPenalty: 1.05,
    seed: nil,
    contextWindow: 500_000,
    stream: true
  )

  public init(
    temperature: Double,
    topP: Double,
    topK: Int,
    maxTokens: Int,
    repetitionPenalty: Double,
    seed: Int?,
    contextWindow: Int,
    stream: Bool
  ) {
    self.temperature = temperature
    self.topP = topP
    self.topK = topK
    self.maxTokens = maxTokens
    self.repetitionPenalty = repetitionPenalty
    self.seed = seed
    self.contextWindow = contextWindow
    self.stream = stream
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let defaults = Self.default
    temperature =
      try container.decodeIfPresent(Double.self, forKey: .temperature) ?? defaults.temperature
    topP = try container.decodeIfPresent(Double.self, forKey: .topP) ?? defaults.topP
    topK = try container.decodeIfPresent(Int.self, forKey: .topK) ?? defaults.topK
    maxTokens = try container.decodeIfPresent(Int.self, forKey: .maxTokens) ?? defaults.maxTokens
    repetitionPenalty =
      try container.decodeIfPresent(Double.self, forKey: .repetitionPenalty)
      ?? defaults.repetitionPenalty
    seed = try container.decodeIfPresent(Int.self, forKey: .seed) ?? defaults.seed
    let decodedContextWindow =
      try container.decodeIfPresent(Int.self, forKey: .contextWindow) ?? defaults.contextWindow
    contextWindow =
      decodedContextWindow == Self.legacyDefaultContextWindow
      ? defaults.contextWindow
      : decodedContextWindow
    stream = try container.decodeIfPresent(Bool.self, forKey: .stream) ?? defaults.stream
  }

  public var streamingByDefault: InferenceParameters {
    var parameters = self
    parameters.stream = true
    return parameters
  }
}

public struct RuntimeStatusSnapshot: Codable, Hashable, Sendable {
  public var state: RuntimeActivityState
  public var activeModelID: UUID?
  public var generatedTokens: Int
  public var tokensPerSecond: Double?
  public var contextUsage: Int
  public var backendLabel: String?
  public var detailMessage: String?
  public var progressFraction: Double?
  public var memoryPressureHint: String?

  public init(
    state: RuntimeActivityState, activeModelID: UUID? = nil, generatedTokens: Int,
    tokensPerSecond: Double? = nil, contextUsage: Int, backendLabel: String? = nil,
    detailMessage: String? = nil, progressFraction: Double? = nil, memoryPressureHint: String? = nil
  ) {
    self.state = state
    self.activeModelID = activeModelID
    self.generatedTokens = generatedTokens
    self.tokensPerSecond = tokensPerSecond
    self.contextUsage = contextUsage
    self.backendLabel = backendLabel
    self.detailMessage = detailMessage
    self.progressFraction = progressFraction
    self.memoryPressureHint = memoryPressureHint
  }
}
