import CryptoKit
import Foundation
import iCordisKernel

public enum ModelOrigin: String, Codable, CaseIterable, Sendable {
  case imported
  case downloaded
  case bundled
  case configured
}

public enum ModelFormat: String, Codable, CaseIterable, Sendable {
  case mlx
  case gguf
  case litertlm
  case safetensors
  case responsesAPI
  case unknown
}

public enum ModelModality: String, Codable, CaseIterable, Sendable {
  case text
  case visionLanguage
  case speech
}

public enum ModelCompanionRole: String, Codable, CaseIterable, Sendable {
  case primaryWeights
  case multimodalProjector
  case configuration
  case tokenizer
  case auxiliary
}

public struct ModelCompanionFile: Codable, Hashable, Identifiable, Sendable {
  public var id: String { path }
  public var role: ModelCompanionRole
  public var path: String
  public var displayName: String
  public var sizeInBytes: Int64?

  public init(
    role: ModelCompanionRole, path: String, displayName: String, sizeInBytes: Int64? = nil
  ) {
    self.role = role
    self.path = path
    self.displayName = displayName
    self.sizeInBytes = sizeInBytes
  }
}

public enum CompatibilityState: String, Codable, CaseIterable, Sendable {
  case compatible
  case partiallyCompatible
  case incompatible
}

public struct ModelCompatibility: Codable, Hashable, Sendable {
  public var state: CompatibilityState
  public var notes: String

  public init(state: CompatibilityState, notes: String) {
    self.state = state
    self.notes = notes
  }
}

public struct LocalModelDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var displayName: String
  public var origin: ModelOrigin
  public var format: ModelFormat
  public var modality: ModelModality
  public var path: String
  public var sizeInBytes: Int64
  public var quantization: String?
  public var companionFiles: [ModelCompanionFile]
  public var metadata: [String: JSONValue]
  public var compatibility: ModelCompatibility
  public var isDefault: Bool
  public var isCached: Bool
  public var isLoaded: Bool
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID,
    displayName: String,
    origin: ModelOrigin,
    format: ModelFormat,
    modality: ModelModality = .text,
    path: String,
    sizeInBytes: Int64,
    quantization: String?,
    companionFiles: [ModelCompanionFile] = [],
    metadata: [String: JSONValue],
    compatibility: ModelCompatibility,
    isDefault: Bool,
    isCached: Bool,
    isLoaded: Bool,
    createdAt: Date,
    updatedAt: Date
  ) {
    self.id = id
    self.displayName = displayName
    self.origin = origin
    self.format = format
    self.modality = modality
    self.path = path
    self.sizeInBytes = sizeInBytes
    self.quantization = quantization
    self.companionFiles = companionFiles
    self.metadata = metadata
    self.compatibility = compatibility
    self.isDefault = isDefault
    self.isCached = isCached
    self.isLoaded = isLoaded
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(UUID.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    origin = try container.decode(ModelOrigin.self, forKey: .origin)
    format = try container.decode(ModelFormat.self, forKey: .format)
    modality = try container.decodeIfPresent(ModelModality.self, forKey: .modality) ?? .text
    path = try container.decode(String.self, forKey: .path)
    sizeInBytes = try container.decode(Int64.self, forKey: .sizeInBytes)
    quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
    companionFiles =
      try container.decodeIfPresent([ModelCompanionFile].self, forKey: .companionFiles) ?? []
    metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    compatibility = try container.decode(ModelCompatibility.self, forKey: .compatibility)
    isDefault = try container.decode(Bool.self, forKey: .isDefault)
    isCached = try container.decode(Bool.self, forKey: .isCached)
    isLoaded = try container.decode(Bool.self, forKey: .isLoaded)
    createdAt = try container.decode(Date.self, forKey: .createdAt)
    updatedAt = try container.decode(Date.self, forKey: .updatedAt)
  }
}

public enum RemoteModelArtifactKind: String, Codable, CaseIterable, Sendable {
  case directFile
  case fileManifest
}

public struct RemoteModelArtifactFile: Codable, Hashable, Identifiable, Sendable {
  public var id: String { relativePath }
  public var relativePath: String
  public var url: String
  public var sizeInBytes: Int64?
  public var checksum: String?

  public init(relativePath: String, url: String, sizeInBytes: Int64? = nil, checksum: String? = nil)
  {
    self.relativePath = relativePath
    self.url = url
    self.sizeInBytes = sizeInBytes
    self.checksum = checksum
  }
}

public struct RemoteModelArtifact: Codable, Hashable, Sendable {
  public var kind: RemoteModelArtifactKind
  public var url: String?
  public var baseURL: String?
  public var files: [RemoteModelArtifactFile]
  public var suggestedFileName: String?

  public init(
    kind: RemoteModelArtifactKind, url: String? = nil, baseURL: String? = nil,
    files: [RemoteModelArtifactFile], suggestedFileName: String? = nil
  ) {
    self.kind = kind
    self.url = url
    self.baseURL = baseURL
    self.files = files
    self.suggestedFileName = suggestedFileName
  }
}

public struct RemoteModelDescriptor: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var displayName: String
  public var summary: String
  public var sourceLabel: String?
  public var format: ModelFormat
  public var modality: ModelModality
  public var artifact: RemoteModelArtifact
  public var sizeInBytes: Int64?
  public var quantization: String?
  public var metadata: [String: JSONValue]
  public var compatibility: ModelCompatibility
  public var recommended: Bool

  public init(
    id: String,
    displayName: String,
    summary: String,
    sourceLabel: String?,
    format: ModelFormat,
    modality: ModelModality = .text,
    artifact: RemoteModelArtifact,
    sizeInBytes: Int64?,
    quantization: String?,
    metadata: [String: JSONValue],
    compatibility: ModelCompatibility,
    recommended: Bool
  ) {
    self.id = id
    self.displayName = displayName
    self.summary = summary
    self.sourceLabel = sourceLabel
    self.format = format
    self.modality = modality
    self.artifact = artifact
    self.sizeInBytes = sizeInBytes
    self.quantization = quantization
    self.metadata = metadata
    self.compatibility = compatibility
    self.recommended = recommended
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    id = try container.decode(String.self, forKey: .id)
    displayName = try container.decode(String.self, forKey: .displayName)
    summary = try container.decodeIfPresent(String.self, forKey: .summary) ?? ""
    sourceLabel = try container.decodeIfPresent(String.self, forKey: .sourceLabel)
    format = try container.decode(ModelFormat.self, forKey: .format)
    modality = try container.decodeIfPresent(ModelModality.self, forKey: .modality) ?? .text
    artifact = try container.decode(RemoteModelArtifact.self, forKey: .artifact)
    sizeInBytes = try container.decodeIfPresent(Int64.self, forKey: .sizeInBytes)
    quantization = try container.decodeIfPresent(String.self, forKey: .quantization)
    metadata = try container.decodeIfPresent([String: JSONValue].self, forKey: .metadata) ?? [:]
    compatibility = try container.decode(ModelCompatibility.self, forKey: .compatibility)
    recommended = try container.decodeIfPresent(Bool.self, forKey: .recommended) ?? false
  }
}

public struct RemoteModelCatalog: Codable, Hashable, Identifiable, Sendable {
  public var id: String
  public var title: String
  public var sourceURL: String
  public var models: [RemoteModelDescriptor]
  public var updatedAt: Date?

  public init(
    id: String, title: String, sourceURL: String, models: [RemoteModelDescriptor],
    updatedAt: Date? = nil
  ) {
    self.id = id
    self.title = title
    self.sourceURL = sourceURL
    self.models = models
    self.updatedAt = updatedAt
  }
}

public enum ModelDownloadState: String, Codable, CaseIterable, Sendable {
  case queued
  case downloading
  case paused
  case failed
  case completed
  case cancelled
}

public struct ModelDownloadRecord: Codable, Hashable, Identifiable, Sendable {
  public var id: UUID
  public var remoteModelID: String
  public var remoteModel: RemoteModelDescriptor
  public var state: ModelDownloadState
  public var bytesReceived: Int64
  public var bytesExpected: Int64?
  public var destinationPath: String
  public var temporaryPath: String
  public var errorDescription: String?
  public var installedModelID: UUID?
  public var createdAt: Date
  public var updatedAt: Date

  public init(
    id: UUID, remoteModelID: String, remoteModel: RemoteModelDescriptor, state: ModelDownloadState,
    bytesReceived: Int64, bytesExpected: Int64? = nil, destinationPath: String,
    temporaryPath: String, errorDescription: String? = nil, installedModelID: UUID? = nil,
    createdAt: Date, updatedAt: Date
  ) {
    self.id = id
    self.remoteModelID = remoteModelID
    self.remoteModel = remoteModel
    self.state = state
    self.bytesReceived = bytesReceived
    self.bytesExpected = bytesExpected
    self.destinationPath = destinationPath
    self.temporaryPath = temporaryPath
    self.errorDescription = errorDescription
    self.installedModelID = installedModelID
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}

extension RemoteModelDescriptor {
  public static func directDownload(url: URL, displayName: String? = nil) -> RemoteModelDescriptor {
    let fileName = url.lastPathComponent.isEmpty ? "model" : url.lastPathComponent
    let resolvedName = displayName ?? url.deletingPathExtension().lastPathComponent
    let inferredFormat = ModelFormat.infer(from: url)
    let inferredModality = inferModality(from: url)
    let inferredRepoID = huggingFaceRepoID(from: url)
    var metadata: [String: JSONValue] = [
      "source.url": .string(url.absoluteString)
    ]
    if let inferredRepoID {
      metadata["huggingface.repo_id"] = .string(inferredRepoID)
    }
    return RemoteModelDescriptor(
      id: "direct-\(stableIdentifier(for: url.absoluteString))",
      displayName: resolvedName.isEmpty ? fileName : resolvedName,
      summary: url.absoluteString,
      sourceLabel: "Direct URL",
      format: inferredFormat,
      modality: inferredModality,
      artifact: RemoteModelArtifact(
        kind: .directFile,
        url: url.absoluteString,
        baseURL: nil,
        files: [],
        suggestedFileName: fileName
      ),
      sizeInBytes: nil,
      quantization: nil,
      metadata: metadata,
      compatibility: ModelCompatibility(
        state: {
          switch inferredFormat {
          case .mlx, .gguf:
            .compatible
          case .responsesAPI:
            .compatible
          case .litertlm, .safetensors:
            .partiallyCompatible
          case .unknown:
            .incompatible
          }
        }(),
        notes: {
          switch (inferredFormat, inferredModality) {
          case (.safetensors, .speech):
            if inferredRepoID != nil {
              "Remote speech model recognized. William can synthesize audio through mlx-audio using the Hugging Face repo."
            } else {
              "Remote speech safetensors artifact recognized, but William still needs the matching Hugging Face repo or a full MLX model directory."
            }
          case (.mlx, _):
            "Remote MLX artifact"
          case (.gguf, _):
            "Remote GGUF artifact"
          case (.responsesAPI, _):
            "Hosted Responses API endpoint"
          case (.litertlm, _):
            "Remote LiteRT-LM artifact"
          case (.safetensors, _):
            "Remote safetensors artifact"
          case (.unknown, _):
            "Unknown remote model artifact"
          }
        }()
      ),
      recommended: false
    )
  }

  public static func stableIdentifier(for value: String) -> String {
    let digest = SHA256.hash(data: Data(value.utf8))
    return digest.compactMap { String(format: "%02x", $0) }.joined().prefix(16).lowercased()
  }

  public static func huggingFaceRepoID(from url: URL) -> String? {
    guard (url.host ?? "").localizedCaseInsensitiveContains("huggingface.co") else {
      return nil
    }

    let components = url.pathComponents.filter { $0 != "/" && !$0.isEmpty }
    guard components.count >= 2 else { return nil }
    guard
      let sentinelIndex = components.firstIndex(where: { ["resolve", "blob", "tree"].contains($0) })
    else {
      return components.count >= 2 ? "\(components[0])/\(components[1])" : nil
    }
    guard sentinelIndex >= 2 else { return nil }
    return "\(components[sentinelIndex - 2])/\(components[sentinelIndex - 1])"
  }

  public static func inferModality(from url: URL) -> ModelModality {
    let token = url.absoluteString.lowercased()
    if token.contains("qwen3-tts") || token.contains("/tts") || token.contains("text-to-speech") {
      return .speech
    }
    if token.contains("gemma-4")
      || token.contains("paligemma")
      || token.contains("qwen-vl")
      || token.contains("qwen3-vl")
      || token.contains("vlm")
      || token.contains("vision")
    {
      return .visionLanguage
    }
    return .text
  }
}

extension ModelFormat {
  public static func infer(from url: URL) -> ModelFormat {
    switch url.pathExtension.lowercased() {
    case "mlx", "json":
      return .mlx
    case "gguf":
      return .gguf
    case "litertlm", "tflite":
      return .litertlm
    case "safetensors":
      return .safetensors
    default:
      return .unknown
    }
  }
}

extension ModelDownloadRecord {
  public var progress: Double? {
    guard let bytesExpected, bytesExpected > 0 else { return nil }
    return min(1, Double(bytesReceived) / Double(bytesExpected))
  }
}
