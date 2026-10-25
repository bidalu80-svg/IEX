import Foundation

// MARK: - Cross-Provider Helpers

/// Sanitize a tool-use ID so it is valid for all providers.
/// Anthropic requires `^[a-zA-Z0-9_-]+$`; OpenAI Responses API can produce
/// IDs containing `|` (e.g. `call_xxx|fc_yyy`).  Replace any disallowed
/// character with `-`.
func sanitizeToolId(_ id: String) -> String {
    let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "_-"))
    return String(id.unicodeScalars.map { allowed.contains($0) ? Character($0) : Character("-") })
}

// MARK: - Canonical Tool Definitions

/// Canonical tool definition used by the agent loop — provider-agnostic.
struct AgentToolDefinition {
    let name: String
    let description: String
    let parameters: [String: AgentToolParam]
    let required: [String]
    /// Explicit property generation order. When provided, providers that support it
    /// (e.g. Gemini) will instruct the model to emit parameters in this order.
    let propertyOrdering: [String]?

    init(name: String, description: String, parameters: [String: AgentToolParam], required: [String], propertyOrdering: [String]? = nil) {
        self.name = name
        self.description = description
        self.parameters = parameters
        self.required = required
        self.propertyOrdering = propertyOrdering
    }
}

struct AgentToolParam {
    let type: AgentParamType
    let description: String
    let enumValues: [String]?

    init(type: AgentParamType, description: String, enumValues: [String]? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
    }
}

enum AgentParamType: String {
    case string
    case integer
    case boolean
}

// MARK: - Agent Messages

/// A single content part in agent messages — provider-agnostic.
enum AgentContentPart: @unchecked Sendable {
    case text(String)
    case toolUse(id: String, name: String, input: [String: Any])
    /// `imageLinuxPath` — iSH-visible linux path the image bytes were
    /// persisted to (e.g. `/var/ze/browser/<sid>/screenshot_*.jpg`,
    /// `/var/ze/attachments/uploads/*`). Carried so the request-level
    /// image budget can emit a re-fetchable text placeholder when the
    /// cumulative payload would exceed the 25MB cap. Defaults to nil for
    /// backward compatibility with existing call sites and persisted
    /// history.
    case toolResult(id: String, name: String, content: String, isError: Bool, imageData: Data? = nil, imageMimeType: String? = nil, pageURL: String? = nil, imageLinuxPath: String? = nil)
    /// `linuxPath` — same semantics as above. Used for user attachments
    /// and read_image results that don't ride through .toolResult.
    case imageData(data: Data, mimeType: String, linuxPath: String? = nil)
}

/// Native reasoning payload captured from the provider response, used to
/// preserve chain-of-thought across multi-turn requests. Lives **in memory
/// only** (not persisted) — restart loses encrypted content, which is
/// acceptable because the visible text + tool history is unchanged.
///
/// Each echo is tagged with the producing model so cross-model switches
/// (e.g. gpt-5.5 → deepseek) can be detected and the encrypted payload
/// stripped — encrypted_content is model-specific and meaningless to a
/// different model family.
struct ReasoningEcho: @unchecked Sendable {
    /// Stable provider family tag; matches `OpenAIAgentProvider.responsesAPIProviderKind`
    /// etc. Different families never share schemas.
    let providerKind: String
    /// Concrete model id (e.g. "gpt-5.5", "o3-mini"). Encrypted payloads are
    /// only safe to echo back to the **same** model id within the same
    /// provider family.
    let modelId: String
    /// Reasoning items captured in original emission order — must be
    /// re-inserted into the next request's input array in the same order
    /// (Responses API rejects out-of-order reasoning items).
    let items: [Item]

    enum Item: @unchecked Sendable {
        /// OpenAI Responses API reasoning item.
        case openaiReasoning(id: String, encryptedContent: String?, summary: [String])
    }
}

/// A message in the agent conversation.
struct AgentMessage: @unchecked Sendable {
    enum Role: String, Sendable { case user, assistant }
    let role: Role
    var parts: [AgentContentPart]
    /// True when this assistant message was interrupted mid-stream (e.g. network drop).
    /// tool_use blocks inside may have incomplete/empty inputs (partialJson never finished).
    /// Placeholder tool_results must NOT be injected for interrupted messages, because
    /// sending a tool_result for a tool_use with empty input causes API 400 errors.
    var isInterrupted: Bool = false
    /// Opaque reasoning content from thinking models (e.g. Kimi, DeepSeek, QwQ).
    /// Must be echoed back on assistant messages for multi-turn conversations.
    var reasoningContent: String?
    /// UI-only frozen duration for the visible reasoning summary. It is not
    /// included in provider requests and is persisted alongside the raw message.
    var reasoningDuration: TimeInterval? = nil
    /// UI-only first-token latency, persisted alongside the raw assistant row.
    var firstTokenLatency: TimeInterval? = nil
    /// UI-only total task duration, persisted alongside the raw assistant row.
    var taskDuration: TimeInterval? = nil
    /// Native reasoning payload (Responses-API encrypted items, etc.). In
    /// memory only — see `ReasoningEcho` for cross-model isolation rules.
    var reasoningEcho: ReasoningEcho?
    /// DB message id (RawMessage.id) once this message has been persisted.
    /// Populated by persistAgentMessage after buildRawMessage succeeds, or by
    /// loadSession on restore. Used by compact logic to resolve marker boundaries
    /// via id instead of sort_order. nil while the message is still in-flight
    /// (e.g. mid-stream before persist).
    var dbMessageId: String? = nil
}

// MARK: - Stream Events

/// Stream events from an agent provider — unified across Anthropic/Gemini.
enum AgentStreamEvent: @unchecked Sendable {
    /// A new content block started (text or tool).
    case contentBlockStart(AgentBlockStart)
    /// Incremental text delta.
    case textDelta(String)
    /// Tool input update (for streaming JSON preview).
    /// `accumulated` is the full JSON so far, `name` is the tool name.
    case toolInputDelta(name: String, accumulated: String)
    /// Tool call completed with final parsed arguments.
    case toolCallComplete(id: String, name: String, args: [String: Any], metadata: ToolCallMetadata?)
    /// Usage stats.
    case usage(LLMUsage)
    /// Real-time thinking content delta for live UI display.
    case thinkingDelta(String)
    /// Accumulated reasoning content from thinking models (opaque, must be echoed back).
    case reasoningContent(String)
    /// Native reasoning payload (e.g. OpenAI Responses-API encrypted items)
    /// for in-memory multi-turn replay. Cross-model isolation rules live on
    /// `ReasoningEcho`.
    case reasoningEcho(ReasoningEcho)
    /// [T-sse-idle-timeout] The server sent real model output that produced no
    /// other event — reasoning that is not being shown because the thinking
    /// level is off. Carries nothing: it only tells the stall watchdog the
    /// stream is alive. Never sent for keepalives, comments or empty chunks.
    case streamActivity
    /// Response finished.
    case done(stopReason: AgentStopReason)
}

enum AgentBlockStart: Sendable {
    case text
    case toolUse(id: String, name: String)
}

enum AgentStopReason: Sendable {
    case endTurn
    case toolUse
    case maxTokens
    /// Anthropic safety classifier declined the request (HTTP 200 + `stop_reason: "refusal"`,
    /// input tokens billed, empty `content`). Distinct from `.endTurn` so the agent loop can
    /// surface an actionable message instead of a generic "empty response" and skip the
    /// pointless transient-retry path (a refusal is deterministic, not transient).
    /// Fires as a false-positive on Fable 5 for benign turns carrying the large Claude Code
    /// agentic system prompt + tool set. See [T-ios-fable5-empty-response].
    case refusal
}

/// Provider-specific metadata attached to a tool call (e.g. Gemini thought signatures).
struct ToolCallMetadata: @unchecked Sendable {
    let thoughtSignature: String?
}

// MARK: - Protocol

/// Protocol for providers that support the agent loop (streaming + tool use).
protocol AgentProvider {
    var name: String { get }
    var model: LLMModel { get }
    /// Default max output tokens for this provider.
    var defaultMaxTokens: Int { get }
    /// [T-sse-idle-timeout] How long the agent loop waits for the next stream
    /// event (the first one included) before calling the stream stalled.
    /// Read from the per-instance setting; the default is 2 minutes.
    var responseIdleTimeout: TimeInterval { get }
    /// [T-sse-idle-timeout] The ProviderInstance this client was built for.
    /// Runtime-only; providers that are not bound to one answer nil and fall
    /// back to the default timeout.
    var providerInstanceId: String? { get }

    /// Provider-specific streaming implementation. Receives a thinking level
    /// that has already been clamped to the model's effective max by the
    /// protocol extension — implementations should NOT re-clamp.
    func streamAgentMessageClamped(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>
}

// BEGIN ResponseIdleTimeoutSetting
/// [T-sse-idle-timeout] The per-provider "response idle timeout": the longest
/// wait for the next piece of a streamed reply, the first piece included. It is
/// NOT a limit on how long a reply may take - a stream that keeps delivering
/// never times out.
///
/// Stored per device in UserDefaults, keyed by provider instance id. Nothing
/// stored means the default, so existing providers behave exactly as before.
/// Deliberately not a ProviderInstance field: that would need a DB column and
/// sync / backup wiring for a value that describes this device's link to one
/// server.
enum ResponseIdleTimeoutSetting {
    static let defaultSeconds = 120
    static let minSeconds = 30
    /// No "never": a stream that really died would leave the turn waiting
    /// forever, holding a session slot and the background keep-alive.
    static let maxSeconds = 3600
    static let presets = [120, 300, 600, 1800, 3600]

    static func clamp(_ seconds: Int) -> Int { min(max(seconds, minSeconds), maxSeconds) }

    static func key(forInstanceId id: String) -> String { "provider.responseIdleTimeout.\(id)" }

    /// The effective value: the stored one, clamped, or the default.
    static func seconds(forInstanceId id: String?, defaults: UserDefaults = .standard) -> Int {
        guard let id, !id.isEmpty, let stored = defaults.object(forKey: key(forInstanceId: id)) as? Int else {
            return defaultSeconds
        }
        return clamp(stored)
    }

    /// Storing the default removes the key, so "default" stays "never set".
    static func set(_ seconds: Int?, forInstanceId id: String, defaults: UserDefaults = .standard) {
        guard let seconds, clamp(seconds) != defaultSeconds else {
            defaults.removeObject(forKey: key(forInstanceId: id))
            return
        }
        defaults.set(clamp(seconds), forKey: key(forInstanceId: id))
    }

    /// The per-request URLSession timeout a streaming request needs so the
    /// transport does not give up before the watchdog does. nil = leave the
    /// session's own 600 s alone.
    static func requestTimeout(forIdleSeconds idle: Int, sessionDefault: Int = 600) -> TimeInterval? {
        idle > sessionDefault ? TimeInterval(idle + 30) : nil
    }

    /// [T-sse-idle-timeout] The same budget resolved for an instance, with the
    /// session default filled in so callers can assign it unconditionally.
    static func transportTimeout(forInstanceId id: String?, sessionDefault: Int = 600) -> TimeInterval {
        requestTimeout(forIdleSeconds: seconds(forInstanceId: id), sessionDefault: sessionDefault)
            ?? TimeInterval(sessionDefault)
    }
}
// END ResponseIdleTimeoutSetting

extension AgentProvider {
    /// [T-sse-idle-timeout] Default for a provider that is not bound to a
    /// ProviderInstance.
    var providerInstanceId: String? { nil }

    /// [T-sse-idle-timeout] Every provider family reads the same per-instance
    /// setting, so raising it works for Anthropic, Gemini, Antigravity and
    /// every OpenAI-compatible vendor alike.
    var responseIdleTimeout: TimeInterval {
        TimeInterval(ResponseIdleTimeoutSetting.seconds(forInstanceId: providerInstanceId))
    }

    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int,
        thinkingLevel: ThinkingLevel
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        let clamped = min(thinkingLevel, model.catalogMaxThinkingLevel)
        return try await streamAgentMessageClamped(
            messages: messages, systemPrompt: systemPrompt,
            tools: tools, maxTokens: maxTokens, thinkingLevel: clamped
        )
    }

    /// Default: thinking off.
    func streamAgentMessage(
        messages: [AgentMessage],
        systemPrompt: String?,
        tools: [AgentToolDefinition],
        maxTokens: Int
    ) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        try await streamAgentMessage(messages: messages, systemPrompt: systemPrompt, tools: tools, maxTokens: maxTokens, thinkingLevel: .off)
    }
}

