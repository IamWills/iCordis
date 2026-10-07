import Foundation
import XCTest
@testable import iCordisAgent

final class AgentPluginsBridgeTests: XCTestCase {
  func testLoadsManifestSkillAndMCPServer() throws {
    let root = try makePluginRoot()
    defer { try? FileManager.default.removeItem(at: root) }

    try write(
      """
      {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name": "example-tools",
        "version": "1.2.3",
        "extensions": {
          "com.icordis": { "mode": "native" }
        }
      }
      """,
      to: root.appendingPathComponent("plugin.json")
    )

    let skillDirectory = root.appendingPathComponent("skills/greet", isDirectory: true)
    try FileManager.default.createDirectory(at: skillDirectory, withIntermediateDirectories: true)
    try write(
      """
      ---
      name: greet
      description: Greet the user.
      ---
      Greet the user and offer help.
      """,
      to: skillDirectory.appendingPathComponent("SKILL.md")
    )

    try write(
      """
      {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers": {
          "deployment-api": {
            "type": "streamable-http",
            "url": "https://example.com/mcp"
          }
        }
      }
      """,
      to: root.appendingPathComponent("mcp.json")
    )

    let package = try AgentPluginLoader().load(root: root)
    XCTAssertEqual(package.specification, .v1_0_0)
    XCTAssertEqual(package.manifest.name, "example-tools")
    XCTAssertEqual(package.skills.map(\.name), ["greet"])
    XCTAssertEqual(package.skillDescriptors.first?.summary, "Greet the user.")
    XCTAssertEqual(package.mcpServerDescriptors.first?.transport, "streamable-http")
    XCTAssertTrue(package.diagnostics.isEmpty)

    guard case .object(let extensionValue)? = package.extensionValue(namespace: "com.icordis") else {
      return XCTFail("Expected com.icordis extension object")
    }
    XCTAssertEqual(extensionValue["mode"], .string("native"))
  }

  func testRejectsUnsupportedSchema() throws {
    let root = try makePluginRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(
      """
      {
        "$schema": "https://agent-plugins.org/schemas/9.0.0/plugin.schema.json",
        "name": "future-plugin"
      }
      """,
      to: root.appendingPathComponent("plugin.json")
    )

    XCTAssertThrowsError(try AgentPluginLoader().load(root: root)) { error in
      guard case AgentPluginsError.unsupportedSchema = error else {
        return XCTFail("Unexpected error: \(error)")
      }
    }
  }

  func testInvalidSkillIsIsolated() throws {
    let root = try makePluginRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try minimalManifest(at: root)

    let good = root.appendingPathComponent("skills/good", isDirectory: true)
    let bad = root.appendingPathComponent("skills/bad", isDirectory: true)
    try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: bad, withIntermediateDirectories: true)
    try write(
      "---\nname: good\ndescription: Valid.\n---\nDo useful work.",
      to: good.appendingPathComponent("SKILL.md")
    )
    try write("not-frontmatter", to: bad.appendingPathComponent("SKILL.md"))

    let package = try AgentPluginLoader().load(root: root)
    XCTAssertEqual(package.skills.map(\.name), ["good"])
    XCTAssertEqual(package.diagnostics.count, 1)
  }

  func testInvalidMCPEntryDoesNotDisableValidServer() throws {
    let root = try makePluginRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try minimalManifest(at: root)
    try write(
      """
      {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/mcp.schema.json",
        "mcpServers": {
          "good": {
            "type": "streamable-http",
            "url": "https://example.com/mcp"
          },
          "bad": {
            "type": "streamable-http",
            "url": "http://example.com/mcp"
          }
        }
      }
      """,
      to: root.appendingPathComponent("mcp.json")
    )

    let package = try AgentPluginLoader().load(root: root)
    XCTAssertEqual(package.mcp?.mcpServers.keys.sorted(), ["good"])
    XCTAssertEqual(package.diagnostics.count, 1)
  }

  func testRejectsInvalidPluginName() throws {
    let root = try makePluginRoot()
    defer { try? FileManager.default.removeItem(at: root) }
    try write(
      """
      {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name": "Invalid--Name"
      }
      """,
      to: root.appendingPathComponent("plugin.json")
    )

    XCTAssertThrowsError(try AgentPluginLoader().load(root: root))
  }

  private func makePluginRoot() throws -> URL {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("icordis-agent-plugin-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }

  private func minimalManifest(at root: URL) throws {
    try write(
      """
      {
        "$schema": "https://agent-plugins.org/schemas/1.0.0/plugin.schema.json",
        "name": "example-plugin"
      }
      """,
      to: root.appendingPathComponent("plugin.json")
    )
  }

  private func write(_ value: String, to url: URL) throws {
    try value.data(using: .utf8)!.write(to: url)
  }
}
