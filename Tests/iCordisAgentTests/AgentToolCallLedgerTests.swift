import Foundation
import Testing
import iCordisAgent

private func call(
  _ capabilityID: String,
  _ arguments: [String: JSONValue] = [:]
) -> AgentToolCall {
  AgentToolCall(capabilityID: capabilityID, arguments: arguments, rationale: nil)
}

private func isCached(_ resolution: AgentToolCallLedger.Resolution) -> Bool {
  if case .cached = resolution { return true }
  return false
}

private func cachedObservation(_ resolution: AgentToolCallLedger.Resolution) -> String? {
  guard case .cached(let observation, _) = resolution else { return nil }
  return observation
}

@Test func ledgerExecutesAnUnseenCall() {
  let ledger = AgentToolCallLedger()
  #expect(
    isCached(ledger.resolve(call(AgentBuiltinToolID.searchCode, ["query": .string("auth")])))
      == false)
}

/// The core behaviour change: a repeat is answered from the previous result
/// rather than blocked. Blocking left the model with nothing, which is exactly
/// the state that made it try the same call again.
@Test func ledgerAnswersAnIdenticalRepeatFromItsReceiptWithoutExecuting() {
  var ledger = AgentToolCallLedger()
  let request = call(AgentBuiltinToolID.searchCode, ["query": .string("auth")])
  ledger.record(
    request, callIndex: 3, observation: "3 matches in AuthService.swift", isFailure: false)

  let resolution = ledger.resolve(request)
  let observation = try? #require(cachedObservation(resolution))
  #expect(observation?.contains("3 matches in AuthService.swift") == true)
  #expect(observation?.contains("tool call #3") == true)
  #expect(observation?.contains("change the arguments") == true)
}

@Test func ledgerTreatsDifferentArgumentsAsADifferentCall() {
  var ledger = AgentToolCallLedger()
  let first = call(
    AgentBuiltinToolID.readCodeFile, ["path": .string("A.swift"), "startLine": .number(1)])
  ledger.record(first, callIndex: 1, observation: "lines 1-400", isFailure: false)

  let next = call(
    AgentBuiltinToolID.readCodeFile, ["path": .string("A.swift"), "startLine": .number(401)])
  #expect(isCached(ledger.resolve(next)) == false)
}

@Test func ledgerIgnoresArgumentOrderingWhenMatchingARepeat() {
  var ledger = AgentToolCallLedger()
  let first = call(
    AgentBuiltinToolID.networkAccess,
    ["url": .string("https://example.com"), "method": .string("GET")])
  let reordered = call(
    AgentBuiltinToolID.networkAccess,
    ["method": .string("GET"), "url": .string("https://example.com")])
  ledger.record(first, callIndex: 1, observation: "200 OK", isFailure: false)

  #expect(isCached(ledger.resolve(reordered)))
}

/// A failure can be transient, so one genuine retry is allowed before the
/// ledger starts answering from its receipt.
@Test func ledgerAllowsOneRetryAfterAFailureThenAnswersFromTheReceipt() {
  var ledger = AgentToolCallLedger()
  let request = call(AgentBuiltinToolID.networkAccess, ["url": .string("https://example.com")])

  ledger.record(request, callIndex: 1, observation: "timeout", isFailure: true)
  #expect(isCached(ledger.resolve(request)) == false)

  ledger.record(request, callIndex: 2, observation: "timeout", isFailure: true)
  #expect(isCached(ledger.resolve(request)))
}

@Test func ledgerKeepsASuccessfulReceiptWhenTheSameCallLaterFails() {
  var ledger = AgentToolCallLedger()
  let request = call(AgentBuiltinToolID.inspectSettings)
  ledger.record(request, callIndex: 1, observation: "settings payload", isFailure: false)
  ledger.record(request, callIndex: 2, observation: "transient failure", isFailure: true)

  #expect(cachedObservation(ledger.resolve(request))?.contains("settings payload") == true)
}

/// Polling an app's UI or rerunning a build legitimately yields new results, so
/// those tools are never answered from cache.
@Test func ledgerNeverCachesToolsWhoseResultCanGenuinelyChange() {
  var ledger = AgentToolCallLedger()
  for toolID in [
    AgentBuiltinToolID.runAppCommand,
    AgentBuiltinToolID.inspectAppUI,
    AgentBuiltinToolID.waitForAppUI,
    AgentBuiltinToolID.runCode,
  ] {
    let request = call(toolID, ["value": .string("same")])
    ledger.record(request, callIndex: 1, observation: "first result", isFailure: false)
    #expect(isCached(ledger.resolve(request)) == false)
  }
}

@Test func ledgerNeverCachesPluginStateOrExportedToolCalls() {
  var ledger = AgentToolCallLedger()
  for request in [
    call(PluginToolIDs.listCapabilityID),
    call(PluginToolIDs.standardCapabilityID, ["section": .string("example")]),
    call(PluginToolIDs.validateCapabilityID, ["packagePath": .string("/tmp/demo.williamplugin")]),
    call(
      PluginToolIDs.lifecycleCapabilityID,
      [
        "pluginID": .string("com.example.demo"),
        "action": .string("start"),
      ]),
    call("plugin.com.example.demo.echo", ["text": .string("hello")]),
  ] {
    ledger.record(request, callIndex: 1, observation: "first result", isFailure: false)
    #expect(isCached(ledger.resolve(request)) == false)
  }
}

@Test func ledgerHonorsRefreshAndClearsPackageReadsAfterAFailedContractTest() {
  var ledger = AgentToolCallLedger()
  let read = call(
    AgentBuiltinToolID.fileSystem,
    [
      "operation": .string("read"),
      "path": .string("/tmp/demo.williamplugin/runtime/main.py"),
    ])
  ledger.record(read, callIndex: 1, observation: "old runtime", isFailure: false)
  #expect(isCached(ledger.resolve(read)))

  let refreshed = call(
    AgentBuiltinToolID.fileSystem,
    [
      "operation": .string("read"),
      "path": .string("/tmp/demo.williamplugin/runtime/main.py"),
      "refresh": .bool(true),
    ])
  #expect(isCached(ledger.resolve(refreshed)) == false)

  ledger.invalidateRepairReads(
    afterFailed: call(
      PluginToolIDs.testCapabilityID,
      [
        "packagePath": .string("/tmp/demo.williamplugin")
      ]))
  #expect(isCached(ledger.resolve(read)) == false)
}

@Test func ledgerInvalidatesPackageReadsAndValidationAfterWorkspaceMutation() {
  var ledger = AgentToolCallLedger()
  let packagePath = "/tmp/demo.williamplugin"
  let read = call(
    AgentBuiltinToolID.fileSystem,
    [
      "operation": .string("read"),
      "path": .string(packagePath + "/william-plugin.json"),
    ])
  let validate = call(
    PluginToolIDs.validateCapabilityID,
    [
      "packagePath": .string(packagePath)
    ])
  let install = call(
    PluginToolIDs.installCapabilityID,
    [
      "packagePath": .string(packagePath)
    ])
  ledger.record(read, callIndex: 1, observation: "version 0.1.0", isFailure: false)
  ledger.record(validate, callIndex: 2, observation: "valid", isFailure: false)
  ledger.record(install, callIndex: 3, observation: "installed", isFailure: false)

  ledger.invalidateAfterSuccessfulCall(
    call(
      AgentBuiltinToolID.fileSystem,
      [
        "operation": .string("edit"),
        "path": .string(packagePath + "/william-plugin.json"),
      ]))

  #expect(isCached(ledger.resolve(read)) == false)
  #expect(isCached(ledger.resolve(validate)) == false)
  #expect(isCached(ledger.resolve(install)) == false)
}

@Test func ledgerInvalidatesPluginDiscoveryAfterLifecycleMutation() {
  var ledger = AgentToolCallLedger()
  let list = call(PluginToolIDs.listCapabilityID)
  let search = call(AgentBuiltinToolID.searchTools, ["query": .string("demo plugin")])
  ledger.record(list, callIndex: 1, observation: "disabled", isFailure: false)
  ledger.record(search, callIndex: 2, observation: "no exported tools", isFailure: false)

  ledger.invalidateAfterSuccessfulCall(
    call(
      PluginToolIDs.lifecycleCapabilityID,
      [
        "pluginID": .string("com.example.demo"),
        "action": .string("start"),
      ]))

  #expect(isCached(ledger.resolve(list)) == false)
  #expect(isCached(ledger.resolve(search)) == false)
}

/// A model that rewords a cosmetic argument on each attempt must not defeat the
/// ledger. Observed in the wild: seven executions of `william.app.user_action`
/// — and seventeen folder prompts to the user — because the model varied its
/// `prompt` text every time.
@Test func ledgerIgnoresCosmeticArgumentsWhenMatchingARepeat() {
  var ledger = AgentToolCallLedger()
  let first = call(
    AgentBuiltinToolID.requestLocalAppAction,
    [
      "action": .string("choose_working_directory"),
      "prompt": .string("William Agent needs a folder for this conversation."),
    ])
  ledger.record(first, callIndex: 1, observation: "已选择 /tmp/shooting", isFailure: false)

  let reworded = call(
    AgentBuiltinToolID.requestLocalAppAction,
    [
      "action": .string("choose_working_directory"),
      "prompt": .string("Please choose a directory so I can build the game."),
    ])
  #expect(isCached(ledger.resolve(reworded)))
  #expect(cachedObservation(ledger.resolve(reworded))?.contains("/tmp/shooting") == true)
}

@Test func ledgerStillSeparatesCallsThatDifferInAMeaningfulArgument() {
  var ledger = AgentToolCallLedger()
  let read = call(
    AgentBuiltinToolID.readCodeFile,
    [
      "path": .string("Game.swift"),
      "rationale": .string("check the render loop"),
    ])
  ledger.record(read, callIndex: 1, observation: "lines 1-400", isFailure: false)

  // Same file, different rationale — cosmetic, so it is a repeat.
  #expect(
    isCached(
      ledger.resolve(
        call(
          AgentBuiltinToolID.readCodeFile,
          [
            "path": .string("Game.swift"),
            "rationale": .string("re-check the render loop"),
          ]))))
  // Different file — a real difference.
  #expect(
    isCached(
      ledger.resolve(
        call(
          AgentBuiltinToolID.readCodeFile,
          [
            "path": .string("Enemy.swift")
          ]))) == false)
}
