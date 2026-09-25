import Foundation
import iCordisKernel

public protocol UserFacingErrorConvertible: Error {
  var userFacingMessage: String { get }
}

public enum AppError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case model(ModelError)
  case inference(InferenceError)
  case storage(StorageError)
  case validation(ValidationError)
  case protocolError(ProtocolAdapterError)
  case mcp(MCPError)
  case skill(SkillError)
  case capability(CapabilityInvocationError)
  case unknown(String)

  public var errorDescription: String? { userFacingMessage }

  public var userFacingMessage: String {
    switch self {
    case .model(let error): error.userFacingMessage
    case .inference(let error): error.userFacingMessage
    case .storage(let error): error.userFacingMessage
    case .validation(let error): error.userFacingMessage
    case .protocolError(let error): error.userFacingMessage
    case .mcp(let error): error.userFacingMessage
    case .skill(let error): error.userFacingMessage
    case .capability(let error): error.userFacingMessage
    case .unknown(let message): message
    }
  }
}

public enum ModelError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case invalidModelLocation
  case incompatibleModel(String)
  case modelInUse
  case notFound
  case importFailed(String)
  case loadFailed(String)
  case catalogFetchFailed(String)
  case downloadFailed(String)

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .invalidModelLocation:
      "选中的文件或目录不是受支持的本地模型。"
    case .incompatibleModel(let detail):
      "模型兼容性检查失败：\(detail)"
    case .modelInUse:
      "当前模型正在使用中，无法删除。"
    case .notFound:
      "未找到指定模型。"
    case .importFailed(let detail):
      "导入模型失败：\(detail)"
    case .loadFailed(let detail):
      "加载模型失败：\(detail)"
    case .catalogFetchFailed(let detail):
      "获取模型目录失败：\(detail)"
    case .downloadFailed(let detail):
      "下载模型失败：\(detail)"
    }
  }
}

public enum InferenceError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case missingModelSelection
  case runtimeUnavailable
  case generationInProgress
  case generationCancelled
  case runtimeFailure(String)

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .missingModelSelection:
      "请先选择一个模型。"
    case .runtimeUnavailable:
      "本地推理运行时当前不可用。"
    case .generationInProgress:
      "当前会话已有进行中的生成任务。"
    case .generationCancelled:
      "生成已取消。"
    case .runtimeFailure(let detail):
      "推理失败：\(detail)"
    }
  }
}

public enum StorageError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case fileSystem(String)
  case encoding(String)
  case decoding(String)
  case notFound

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .fileSystem(let detail):
      "本地存储访问失败：\(detail)"
    case .encoding(let detail):
      "数据编码失败：\(detail)"
    case .decoding(let detail):
      "数据解码失败：\(detail)"
    case .notFound:
      "本地数据不存在。"
    }
  }
}

public enum ValidationError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case emptyMessage
  case invalidConfiguration(String)
  case invalidURL

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .emptyMessage:
      "请输入消息内容。"
    case .invalidConfiguration(let detail):
      "配置无效：\(detail)"
    case .invalidURL:
      "无效的文件地址。"
    }
  }
}

public enum ProtocolAdapterError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case unsupported(String)
  case serializationFailed(String)

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .unsupported(let detail):
      "协议适配失败：\(detail)"
    case .serializationFailed(let detail):
      "协议对象序列化失败：\(detail)"
    }
  }
}

public enum MCPError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case unavailableServer(String)
  case timeout
  case invocationFailed(String)

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .unavailableServer(let name):
      "MCP Server 不可用：\(name)"
    case .timeout:
      "MCP 调用超时。"
    case .invocationFailed(let detail):
      "MCP 调用失败：\(detail)"
    }
  }
}

public enum SkillError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case notFound(String)
  case invocationFailed(String)

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .notFound(let name):
      "未找到 Skill：\(name)"
    case .invocationFailed(let detail):
      "Skill 执行失败：\(detail)"
    }
  }
}

public enum CapabilityInvocationError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case capabilityDisabled
  case unsupportedTarget(String)
  case routingFailed(String)

  public var errorDescription: String? { userFacingMessage }
  public var userFacingMessage: String {
    switch self {
    case .capabilityDisabled:
      "能力调用已被禁用。"
    case .unsupportedTarget(let name):
      "不支持的能力目标：\(name)"
    case .routingFailed(let detail):
      "能力调用路由失败：\(detail)"
    }
  }
}

public enum UserFacingErrorMapper {
  public static func message(for error: Error) -> String {
    if let convertible = error as? UserFacingErrorConvertible {
      return convertible.userFacingMessage
    }
    if let appError = error as? AppError {
      return appError.userFacingMessage
    }
    if let localized = error as? LocalizedError {
      let parts = [
        localized.errorDescription,
        localized.failureReason,
        localized.recoverySuggestion,
      ]
      .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty }
      if !parts.isEmpty {
        return parts.joined(separator: " ")
      }
    }
    let localizedDescription = error.localizedDescription.trimmingCharacters(
      in: .whitespacesAndNewlines)
    if !localizedDescription.isEmpty,
      localizedDescription != "The operation couldn’t be completed."
    {
      return localizedDescription
    }
    return "发生了未知错误，请查看诊断日志。"
  }
}
