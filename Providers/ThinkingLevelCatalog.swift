import Foundation

enum ThinkingLevelCatalog {
    /// Opus 5.5 always reasons; its lowest request setting is adaptive + low.
    /// Unknown families retain the existing UI behavior until verified.
    static func supportsThinkingOff(for modelId: String) -> Bool {
        ThinkingRuleResolver.claude55Family(modelId) != "opus"
    }

    static func normalizedLevel(_ level: ThinkingLevel, for modelId: String,
                                maximum: ThinkingLevel) -> ThinkingLevel {
        let capped = level == .off ? level : min(level, maximum)
        return supportsThinkingOff(for: modelId) ? capped : max(.low, capped)
    }

    private static let rules: [(match: (String) -> Bool, max: ThinkingLevel)] = [
        // GPT-5.6 sol/terra/luna all reach .max. (.ultra is a client-side
        // "Max + orchestration" concept — the wire effort tops out at "max",
        // reasoningEffort(for:level:) maps both .max and .ultra to "max".)
        ({ $0.hasPrefix("gpt-5.6-sol") || $0.hasPrefix("gpt-5.6-terra") }, .max),
        ({ $0.hasPrefix("gpt-5.6-luna") }, .max),
        ({ $0.hasPrefix("gpt-5.5") }, .xhigh),
        // GPT-6 Astra and compatible gateway aliases expose the standard
        // reasoning_effort ladder. The actual capability flag is still taken
        // from /models when available; this rule only sets the UI ceiling.
        ({
            let id = LLMModel.modelIdentifierWithoutNamespace($0)
            return id.hasPrefix("gpt-6") || id.hasPrefix("gpt6")
        }, .max),
        // MiMo ships BOTH id spellings in the wild: catalog docs say
        // "MiMo-2.5" but the live API (api.xiaomimimo.com /v1/models) returns
        // "mimo-v2.5" / "mimo-v2.5-pro" — the old "mimo-2.5" substring missed
        // those, so the wrapper clamp passed xhigh straight through to a
        // backend that 400s on it (verified on-device 2026-07-21). Match the
        // family, not one spelling.
        ({ $0.contains("mimo") || $0.contains("agnes") }, .high),
        // ByteDance seed (Volcano Ark "seed-1.6…"/"seed-2.0…", OpenRouter
        // "bytedance-seed/…"): rejects xhigh with "Invalid reasoning_effort:
        // xhigh" — the field report behind T-fallback-thinking-preclamp. Ark's
        // ladder tops out at high.
        ({ $0.contains("seed-") || $0.contains("bytedance-seed") }, .high),
        ({ ThinkingRuleResolver.claude55Family($0) != nil }, .max),
        ({ $0.split(separator: "/").last == "deepseek-flash" || $0.contains("deepseek-v4") }, .max),
        // Claude Opus 4.x — model IDs use hyphens (claude-opus-4-8) in the
        // built-in catalog but third-party proxies may return dots
        // (claude-opus-4.8). Normalize to match both.
        ({ Self.normalizedHasPrefix($0, "claude-opus-4") }, .max),
    ]

    static func declaredMaxLevel(for modelId: String) -> ThinkingLevel? {
        let lid = modelId.lowercased()
        return rules.first { $0.match(lid) }?.max
    }

    private static func normalizedHasPrefix(_ id: String, _ prefix: String) -> Bool {
        let normalized = id.replacingOccurrences(of: ".", with: "-")
        return normalized.hasPrefix(prefix)
    }
}
