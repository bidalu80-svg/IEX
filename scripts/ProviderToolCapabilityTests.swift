import Foundation

// Compile alongside the production Providers/AgentProvider.swift. These are
// dependency-only fixtures; capability filtering itself comes from production.
struct LLMModel {
    let catalogMaxThinkingLevel: ThinkingLevel = .high
}
struct LLMUsage: Sendable {}
enum ThinkingLevel: Int, Comparable {
    case off, high
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

final class RecordingProvider: AgentProvider {
    let supportsNativeTools: Bool
    let name = "Fixture"
    let model = LLMModel()
    let defaultMaxTokens = 100
    var receivedTools: [String] = []
    var receivedSystem: String?
    var receivedMessages: [AgentMessage] = []
    init(tools: Bool) { supportsNativeTools = tools }

    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        receivedTools = tools.map(\.name)
        receivedSystem = systemPrompt
        receivedMessages = messages
        return AsyncThrowingStream { continuation in
            continuation.yield(.textDelta("hello"))
            continuation.yield(.done(stopReason: .endTurn))
            continuation.finish()
        }
    }
}

@main
enum ProviderToolCapabilityTests {
    static func main() async throws {
        let tools = [AgentToolDefinition(name: "spawn_agent", description: "tool", parameters: [:], required: [])]
        let messages = [AgentMessage(role: .user, parts: [.text("hello")])]
        let textOnly = RecordingProvider(tools: false)
        let agent = RecordingProvider(tools: true)
        // Existential dispatch is how fallback and the main agent loop call it.
        for concrete in [textOnly, agent] {
            let provider: any AgentProvider = concrete
            let stream = try await provider.streamAgentMessage(messages: messages,
                systemPrompt: "Use spawn_agent to delegate", tools: tools, maxTokens: 100, thinkingLevel: .off)
            var output = ""
            for try await event in stream { if case .textDelta(let text) = event { output += text } }
            precondition(output == "hello", "Text streaming must remain usable")
            precondition(concrete.receivedMessages.count == 1, "User history must reach transport")
        }
        precondition(textOnly.receivedTools.isEmpty, "Text-only connection must not receive native tools")
        precondition(textOnly.receivedSystem?.contains("spawn_agent") == false, "Text-only system must not advertise unavailable tools")
        precondition(agent.receivedTools == ["spawn_agent"], "Existing tool-capable routes must keep their tools")
        precondition(agent.receivedSystem == "Use spawn_agent to delegate", "Existing system prompt must remain intact")
        print("Provider tool capability tests passed")
    }
}
