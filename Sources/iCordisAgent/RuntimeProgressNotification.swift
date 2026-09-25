import Foundation
import iCordisKernel

public enum RuntimeProgressNotification {
  public static let didUpdate = Notification.Name("William.runtimeProgress.didUpdate")

  /// Lifecycle phase of a tool/capability invocation, carried alongside a
  /// progress update so observers (e.g. the long-running-tool watchdog) can key
  /// off structured state instead of parsing the human `detail` string.
  public enum ToolPhase: String {
    case started
    case finished
  }

  public static func post(
    backend: String? = nil,
    detail: String? = nil,
    progressFraction: Double? = nil,
    capabilityID: String? = nil,
    toolPhase: ToolPhase? = nil
  ) {
    NotificationCenter.default.post(
      name: didUpdate,
      object: nil,
      userInfo: [
        "backend": backend as Any,
        "detail": detail as Any,
        "progressFraction": progressFraction as Any,
        "capabilityID": capabilityID as Any,
        "toolPhase": toolPhase?.rawValue as Any,
      ]
    )
  }
}
