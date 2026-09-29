import Foundation

// MARK: - Provider Type

/// The LLM provider backend.
enum ProviderType: String, Codable, CaseIterable, Hashable, Sendable {
    case openAI
    case anthropic
    case gemini
    case antigravity
    case openRouter
    /// OpenAI Responses API — uses the /v1/responses endpoint format.
    /// Works with OpenAI directly or any Responses-API-compatible service.
    case openAIResponses
    /// xAI Grok (SuperGrok / X Premium+ OAuth). OpenAI-compatible API,
    /// flows through OpenAIProvider with custom base URL + OAuth bearer.
    case xAI
    /// Kimi Code / Coding Plan (Moonshot). RFC 8628 device-code OAuth,
    /// OpenAI-compatible coding upstream — flows through OpenAIProvider with
    /// custom base URL + OAuth bearer, like xAI. See the Kimi Code OAuth design notes.
    case kimiCode
    /// GitHub Copilot Chat API. Uses a Copilot session token or a GitHub token that can be exchanged for one.
    case githubCopilot
    /// Sentinel for a provider type this app build doesn't recognize — e.g. a
    /// NEWER build synced an instance whose `provider_type` string isn't a known
    /// case here. We DECODE to this instead of throwing/dropping, so the instance
    /// is preserved (shown as "Unsupported", unusable) and not silently rewritten
    /// to a wrong type on the next save. The original raw string is kept alongside
    /// (see ProviderInstance.unknownProviderTypeRaw) for faithful round-tripping.
    case unsupported

    /// Decode a raw provider-type string, never throwing: an unrecognized value
    /// maps to `.unsupported` (forward-compat with newer builds).
    static func decoded(_ raw: String) -> ProviderType {
        ProviderType(rawValue: raw) ?? .unsupported
    }

    var displayName: String {
        switch self {
        case .anthropic: return "Anthropic"
        case .gemini: return "Google Gemini"
        case .openAI: return "OpenAI"
        case .antigravity: return "Antigravity"
        case .openRouter: return "OpenRouter"
        case .openAIResponses: return "Responses API (v3)"
        case .xAI: return "xAI (Grok)"
        case .kimiCode: return String(localized: "Kimi Code")
        case .githubCopilot: return "GitHub Copilot"
        case .unsupported: return "Unsupported"
        }
    }

    /// Built-in models for this provider type.
    var builtInModels: [LLMModel] {
        switch self {
        case .anthropic: return LLMModel.allAnthropic
        case .gemini: return LLMModel.allGemini
        case .openAI: return LLMModel.allOpenAI
        case .antigravity: return LLMModel.allAntigravity
        case .openRouter: return LLMModel.allOpenRouter
        case .openAIResponses: return LLMModel.allOpenAI
        case .xAI: return XAIModelsAPI.allModels
        case .kimiCode: return KimiModelsAPI.allModels
        case .githubCopilot: return GitHubCopilotModelsAPI.allModels
        case .unsupported: return []
        }
    }

    /// Short description shown under the provider name in the Add Provider
    /// picker — what kinds of services this protocol supports, rather than a
    /// raw built-in model count. Localized; English key, translations in
    /// Localizable.xcstrings.
    var pickerSubtitle: String {
        switch self {
        case .openAI, .openAIResponses:
            return String(localized: "Works with Codex, DeepSeek, Moonshot, Groq and other compatible vendors")
        case .anthropic:
            return String(localized: "Works with Claude and Anthropic-protocol-compatible services")
        case .gemini:
            return String(localized: "Works with the Gemini series and Google AI Studio")
        case .openRouter:
            return String(localized: "Aggregates GPT, Claude, Gemini, Llama and other mainstream models")
        case .xAI:
            return String(localized: "Works with the Grok series of models")
        case .kimiCode:
            return String(localized: "Sign in with your Kimi Code / Coding Plan subscription")
        case .githubCopilot:
            return String(localized: "使用 GitHub 账号通过 OAuth 登录")
        case .antigravity:
            return String(localized: "\(builtInModels.count) built-in models")
        case .unsupported:
            return String(localized: "\(builtInModels.count) built-in models")
        }
    }

    /// Default modality assumed for custom models added to this provider.
    var defaultModality: ModelModality {
        switch self {
        case .anthropic: return .vision
        case .gemini:    return .fullMultimodal
        case .openAI:    return .vision
        case .antigravity: return .fullMultimodal
        case .openRouter: return .vision
        case .openAIResponses: return .vision
        case .xAI: return .vision
        case .kimiCode: return .vision
        case .githubCopilot: return .vision
        case .unsupported: return .vision
        }
    }

    /// True when this build can't actually use the provider (synced from a newer app).
    var isUnsupported: Bool { self == .unsupported }
}

// MARK: - Credential Type

/// How a provider instance authenticates.
enum ProviderCredential: String, Codable, Hashable, Sendable {
    case apiKey
    case oauth
}


/// Built-in models exposed by GitHub Copilot Chat. The service may expose a
/// different set for an account; users can still add a custom model entry.
enum GitHubCopilotModelsAPI {
    static let allModels: [LLMModel] = [
        LLMModel(id: "gpt-4o", displayName: "GPT-4o", provider: "GitHub Copilot"),
        LLMModel(id: "gpt-4.1", displayName: "GPT-4.1", provider: "GitHub Copilot"),
        LLMModel(id: "o3-mini", displayName: "o3-mini", provider: "GitHub Copilot"),
        LLMModel(id: "claude-3.7-sonnet", displayName: "Claude 3.7 Sonnet", provider: "GitHub Copilot"),
        LLMModel(id: "claude-sonnet-4", displayName: "Claude Sonnet 4", provider: "GitHub Copilot"),
        LLMModel(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: "GitHub Copilot"),
    ]
}
