import Foundation
import iCordisKernel

public enum AgentError: Error, LocalizedError, UserFacingErrorConvertible, Sendable {
  case emptyTask
  case invalidAction(String)
  case maxIterationsExceeded
  case maxToolCallsExceeded
  case toolUnavailable(String)
  case disabled
  case cancelled

  public var errorDescription: String? { userFacingMessage }

  public var userFacingMessage: String {
    switch self {
    case .emptyTask:
      "请输入 Agent 要完成的任务。"
    case .invalidAction(let detail):
      "Agent 输出的操作格式无效：\(detail)"
    case .maxIterationsExceeded:
      "Agent 已达到最大推理步数，已停止继续执行。"
    case .maxToolCallsExceeded:
      "Agent 已达到最大工具调用次数，已停止继续执行。"
    case .toolUnavailable(let name):
      "Agent 请求的工具不可用：\(name)"
    case .disabled:
      "Agent 当前已关闭。请在聊天右侧边栏的 Agent 设置中开启后再使用 /agent。"
    case .cancelled:
      "Agent 已取消。"
    }
  }
}
