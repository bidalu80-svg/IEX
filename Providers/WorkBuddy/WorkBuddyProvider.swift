import Foundation

/// Reuses the existing Chat Completions encoding/parser. Credentials and
/// WorkBuddy's wire differences are resolved at the actual request boundary.
final class WorkBuddyProvider: LLMProvider {
    let name = "WorkBuddy"
    var model: LLMModel
    let instanceId: String
    private let conversationID = WorkBuddyRequestAdapter.newID()

    init(instanceId: String, model: LLMModel) {
        self.instanceId = instanceId
        self.model = model
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        // The upstream always streams, including title/summary calls.
        let stream = try await streamMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
        var text = ""
        var usage: LLMUsage?
        var reason: String?
        for try await chunk in stream {
            switch chunk {
            case .started: break
            case .text(let delta): text += delta
            case .usage(let value): usage = value
            case .finished(let value): reason = value
            }
        }
        return LLMResponse(text: text, stopReason: reason, usage: usage)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        let provider = Self.makeTransport(instanceId: instanceId, model: model, conversationID: conversationID, turnID: WorkBuddyRequestAdapter.newID())
        return try await provider.streamMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
    }

    static func makeTransport(instanceId: String, model: LLMModel, conversationID: String, turnID: String) -> OpenAIProvider {
        // A placeholder key is replaced in requestAdapter before any network I/O.
        // Keeping API-key mode selects Chat Completions instead of Codex Responses.
        let provider = OpenAIProvider(apiKey: "", model: model, customBaseURL: "https://copilot.tencent.com/v2", appendV1Suffix: false)
        provider.providerInstanceId = instanceId
        provider.thinkingRuleInstanceId = instanceId
        provider.streamValidatorFactory = WorkBuddyRequestAdapter.streamValidator
        provider.requestAdapter = { request in
            try await WorkBuddyRequestAdapter.adapt(request, instanceId: instanceId, model: model, conversationID: conversationID, turnID: turnID)
        }
        return provider
    }
}

final class WorkBuddyAgentProvider: AgentProvider {
    let name = "WorkBuddy"
    let model: LLMModel
    let instanceId: String
    var providerInstanceId: String? { instanceId }
    var defaultMaxTokens: Int { min(model.maxOutputTokens ?? 16_384, 16_384) }
    private let conversationID = WorkBuddyRequestAdapter.newID()

    init(instanceId: String, model: LLMModel) {
        self.instanceId = instanceId
        self.model = model
    }

    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int, thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        // A deterministic turn key keeps tool follow-ups grouped with their
        // triggering user message, while a new user turn gets a new key.
        let userTurns = messages.filter { message in
            guard message.role == .user else { return false }
            return message.parts.contains { part in
                switch part {
                case .text, .imageData: return true
                default: return false
                }
            }
        }.count
        let turnID = turnIdentifier(userTurns)
        let credentials = try await WorkBuddyOAuthManager.shared.validCredentials(instanceId: instanceId)
        let capabilities = try await WorkBuddyModelsAPI.requiredCapabilities(instanceId: instanceId, modelID: model.id, credentials: credentials)
        let supportsTools = capabilities.supportsTools == true
        let effectiveTools = supportsTools ? tools : []
        let effectiveSystem = supportsTools ? systemPrompt : "Answer the user's message directly. Tool execution is unavailable for this model."
        let provider = WorkBuddyProvider.makeTransport(instanceId: instanceId, model: model, conversationID: conversationID, turnID: turnID)
        return try await OpenAIAgentProvider(provider: provider).streamAgentMessageClamped(messages: messages, systemPrompt: effectiveSystem, tools: effectiveTools, maxTokens: maxTokens, thinkingLevel: thinkingLevel)
    }

    private var turnIDs: [Int: String] = [:]
    private let lock = NSLock()

    private func turnIdentifier(_ turn: Int) -> String {
        lock.lock()
        defer { lock.unlock() }
        if let value = turnIDs[turn] { return value }
        let value = WorkBuddyRequestAdapter.newID()
        turnIDs[turn] = value
        return value
    }
}
