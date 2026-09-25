import Foundation
import iCordisKernel

public actor AgentCompletionGate {
  private let registeredAppService: (any AgentRegisteredAppProviding)?
  private let sessionRepository: SessionRepositoryProtocol?

  public init(
    registeredAppService: (any AgentRegisteredAppProviding)? = nil,
    sessionRepository: SessionRepositoryProtocol? = nil
  ) {
    self.registeredAppService = registeredAppService
    self.sessionRepository = sessionRepository
  }

  public func evaluate(
    requirements: Set<AgentRunRequirement>,
    evidence: AgentRunEvidence,
    session: ConversationSession,
    taskIntent: AgentTaskIntent? = nil
  ) async -> AgentCompletionGateResult {
    let currentSession =
      if let sessionRepository,
        let persisted = try? await sessionRepository.loadSession(id: session.id)
      {
        persisted
      } else {
        session
      }
    var unmet: [String] = []

    if let taskIntent, taskIntent.requiresPluginDevelopmentEvidence {
      unmet += evidence.pluginDevelopmentUnmetRequirements()
    } else if let taskIntent, taskIntent.requiresPluginInvocationEvidence,
      evidence.pluginInvocations.isEmpty
    {
      unmet.append(
        "The task requested a Plugin invocation, but no exported plugin.* Tool completed successfully."
      )
    }

    if requirements.contains(.workingDirectorySelected), currentSession.workingDirectory == nil {
      unmet.append(
        "No user-authorized App root is selected. Call william.app.user_action with action choose_working_directory before creating files."
      )
    }
    // Only editing existing content can be done "blind". Creating a file in
    // a new workspace has nothing to search for, and failing the run for it
    // punished the agent for work it was explicitly allowed to do.
    if requirements.contains(.codeSearchBeforeEdit),
      evidence.successfulExistingContentEdits > 0,
      evidence.hasSuccessfulCodeSearch == false
    {
      unmet.append("Existing code was edited without a successful william.code.search observation.")
    }

    if requirements.contains(.appRegistered) || requirements.contains(.appOpenedInWilliam) {
      guard
        let verifiedApp = await verifiedCurrentRunApp(evidence: evidence, session: currentSession)
      else {
        unmet.append(
          "No available App from this run is registered with its root exactly equal to the user-selected working directory. Call william.app.register with rootPath=. and use its returned App ID."
        )
        return AgentCompletionGateResult(isSatisfied: false, unmetRequirements: unmet)
      }
      if requirements.contains(.appOpenedInWilliam),
        verifiedApp.kind != .script,
        evidence.wasOpenedAfterRegistration(verifiedApp.id) == false
      {
        unmet.append(
          "The registered UI App has not been opened successfully in William. Call william.app.open with App ID \(verifiedApp.id.uuidString) and debug the semantic UI returned by that tool."
        )
      }
    }

    return AgentCompletionGateResult(isSatisfied: unmet.isEmpty, unmetRequirements: unmet)
  }

  private func verifiedCurrentRunApp(
    evidence: AgentRunEvidence,
    session: ConversationSession
  ) async -> RegisteredAppRecord? {
    guard let registeredAppService,
      let workspacePath = session.workingDirectory?.resolvedURL().standardizedFileURL.path
    else {
      return nil
    }
    let orderedIDs = evidence.registeredAppIDs.sorted { $0.value > $1.value }.map(\.key)
    for id in orderedIDs {
      guard let app = try? await registeredAppService.loadApp(id: id),
        app.isAvailable,
        app.sourceSessionID == session.id
      else {
        continue
      }
      let root = app.resolvedRootURL.standardizedFileURL.path
      // The selected directory is the App root, not merely a broad parent
      // workspace. This preserves the user's explicit directory boundary.
      if root == workspacePath {
        return app
      }
    }
    return nil
  }
}
