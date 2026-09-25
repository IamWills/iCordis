import Foundation

/// Portable discovery tools. Application tools arrive through ToolProviderPlugin.
public struct StandardAgentTools: AgentBuiltinToolProviding {
    public init() {}
    public func descriptors() async -> [CapabilityDescriptor] {
        [CapabilityDescriptor(id: AgentBuiltinToolID.searchTools, kind: .builtin, name: "Search Tools",
            summary: "Find available tools by query. Matching tools become callable on the next turn.",
            schema: CapabilityParameterSchema(type: "object", properties: [
                "query": .object(["type": .string("string")]),
                "limit": .object(["type": .string("integer")])
            ], required: ["query"]), isEnabled: true, metadata: [:])]
    }
    public func invoke(_ request: CapabilityInvocationRequest, catalog: AgentToolCatalog,
                       currentSession: ConversationSession) async throws -> CapabilityExecutionTrace {
        guard request.capabilityID == AgentBuiltinToolID.searchTools else {
            throw AgentError.toolUnavailable(request.capabilityID)
        }
        let start = Date()
        let query = request.arguments["query"]?.stringValue ?? ""
        let matches = catalog.search(query: query, limit: Int(min(20, max(1, request.arguments["limit"]?.pluginNumberValue ?? 8))))
        let payload: JSONValue = .object(["tools": .array(matches.map {
            .object(["id": .string($0.id), "summary": .string($0.summary)])
        })])
        return CapabilityExecutionTrace(id: UUID(), request: request,
            result: CapabilityInvocationResult(capabilityID: request.capabilityID, success: true,
                content: [.text(matches.map { "\($0.id): \($0.summary)" }.joined(separator: "\n"))],
                rawPayload: payload, latency: 0), startedAt: start, finishedAt: .now)
    }
}
