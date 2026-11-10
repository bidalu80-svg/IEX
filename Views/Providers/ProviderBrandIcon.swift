import SwiftUI

/// Bundled vendor artwork shared by provider settings, creation and chat chrome.
/// Unknown compatible hosts retain their selected protocol's mark; display names
/// never determine identity, and drawing an icon performs no network requests.
struct ProviderBrandIcon: View {
    let type: ProviderType
    var baseURL: String? = nil
    var size: CGFloat = 25

    var body: some View {
        Group {
            if type == .workBuddy {
                Image("WorkBuddy").resizable().scaledToFit()
            } else if type == .githubCopilot {
                GitHubCopilotIcon()
            } else if let asset = Self.assetName(type: type, baseURL: baseURL) {
                Image(asset).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: "questionmark.square")
                    .resizable().scaledToFit().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel(type.displayName)
    }

    static func assetName(type: ProviderType, baseURL: String? = nil) -> String? {
        // OAuth-specific brands must not change with an optional custom endpoint.
        if type == .workBuddy || type == .githubCopilot { return nil }
        if let host = baseURL.flatMap({ URL(string: $0)?.host })?.lowercased(),
           [ProviderType.openAI, .openAIResponses, .anthropic].contains(type) {
            // Match DNS boundaries, never substrings such as openai.com.evil.test.
            let vendors: [(String, [String])] = [
                ("ElevenLabs", ["elevenlabs.io"]),
                ("Deepgram", ["deepgram.com"]),
                ("Azure", ["speech.microsoft.com", "openai.azure.com", "cognitiveservices.azure.com"]),
                ("MiniMax", ["minimax.io", "minimaxi.com", "minimax.chat"]),
                ("Bailian", ["dashscope.aliyuncs.com", "dashscope-intl.aliyuncs.com"]),
                ("Volcengine", ["openspeech.bytedance.com", "volcengineapi.com", "volces.com"]),
                ("IFlytek", ["xfyun.cn"]),
                ("MiMo", ["xiaomimimo.com"]),
                ("DeepSeek", ["deepseek.com"]),
                ("Moonshot", ["moonshot.cn", "moonshot.ai"]),
                ("Groq", ["groq.com"]),
                ("OpenRouter", ["openrouter.ai"]),
                ("XAI", ["x.ai"]),
            ]
            if let vendor = vendors.first(where: { _, domains in
                domains.contains { host == $0 || host.hasSuffix("." + $0) }
            }) {
                return "ProviderBrand" + vendor.0
            }
        }
        switch type {
        case .openAI, .openAIResponses: return "ProviderBrandOpenAI"
        case .anthropic: return "ProviderBrandAnthropic"
        case .gemini: return "ProviderBrandGemini"
        case .antigravity: return "ProviderBrandAntigravity"
        case .openRouter: return "ProviderBrandOpenRouter"
        case .xAI: return "ProviderBrandXAI"
        case .kimiCode: return "ProviderBrandKimi"
        case .githubCopilot, .workBuddy, .unsupported: return nil
        }
    }
}

/// Templates have known vendor identity before an instance has been created.
struct VoiceProviderBrandIcon: View {
    let templateID: String
    var size: CGFloat = 25

    static func assetName(templateID: String) -> String? {
        let names = ["elevenlabs": "ElevenLabs", "deepgram": "Deepgram",
                     "azure-tts": "Azure", "minimax": "MiniMax", "alibaba": "Bailian",
                     "doubao": "Volcengine", "xunfei": "IFlytek", "mimo": "MiMo"]
        return names[templateID].map { "ProviderBrand" + $0 }
    }

    var body: some View {
        Group {
            if let asset = Self.assetName(templateID: templateID) {
                Image(asset).renderingMode(.original).resizable().scaledToFit()
            } else {
                Image(systemName: "questionmark.square").resizable().scaledToFit()
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}
