import XCTest
@testable import iCordisAgent

final class AgentExecutionBudgetTests: XCTestCase {
  func testModelTurnLimit() async throws {
    let run = AgentExecutionBudgetRun(maxModelTurns: 2)
    try await run.admitModelTurn()
    try await run.admitModelTurn()
    do {
      try await run.admitModelTurn()
      XCTFail("Expected model-turn budget exhaustion")
    } catch let error as AgentExecutionBudgetError {
      XCTAssertEqual(error, .modelTurnsExhausted(limit: 2))
    }
    let snapshot = await run.snapshot()
    XCTAssertEqual(snapshot.modelTurns, 2)
  }

  func testToolCallLimit() async throws {
    let run = AgentExecutionBudgetRun(maxToolCalls: 1)
    try await run.admitToolCall()
    do {
      try await run.admitToolCall()
      XCTFail("Expected tool-call budget exhaustion")
    } catch let error as AgentExecutionBudgetError {
      XCTAssertEqual(error, .toolCallsExhausted(limit: 1))
    }
  }

  func testRunIsolation() async throws {
    let policy = AgentExecutionBudgetService(makeRun: { _ in
      AgentExecutionBudgetRun(maxModelTurns: 1, maxToolCalls: 1)
    })
    let first = await policy.makeRun(UUID())
    let second = await policy.makeRun(UUID())
    try await first.admitModelTurn()
    try await second.admitModelTurn()
    let firstSnapshot = await first.snapshot()
    let secondSnapshot = await second.snapshot()
    XCTAssertEqual(firstSnapshot.modelTurns, 1)
    XCTAssertEqual(secondSnapshot.modelTurns, 1)
  }

  func testZeroBudgetRejectsFirstCall() async {
    let run = AgentExecutionBudgetRun(maxModelTurns: 0, maxToolCalls: 0)
    do {
      try await run.admitModelTurn()
      XCTFail("Expected zero-budget rejection")
    } catch {
      XCTAssertEqual(error as? AgentExecutionBudgetError, .modelTurnsExhausted(limit: 0))
    }
  }
}
