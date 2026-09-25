import Foundation
import OSLog

/// SDK diagnostics omit model and tool payloads by default.
public enum AgentLogCategory {
  public static let app = AgentLogger()
  public static let capability = AgentLogger()
}
public struct AgentLogger: Sendable {
  private let logger = Logger(subsystem: "org.icordis.agent", category: "runtime")
  public func debug(_ message: String) { logger.debug("\(message, privacy: .private)") }
  public func info(_ message: String) { logger.info("\(message, privacy: .private)") }
  public func error(_ message: String) { logger.error("\(message, privacy: .private)") }

  public init() {}
}
