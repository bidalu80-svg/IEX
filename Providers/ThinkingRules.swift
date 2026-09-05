import Foundation

/// A user-defined request-shape override for an OpenAI-compatible provider.
/// Rules are evaluated in list order; the first matching rule wins.
struct ThinkingRule: Identifiable, Equatable {
    enum Scope: Equatable {
        case allModels
        case modelPattern(String)

        func matches(_ modelId: String) -> Bool {
            switch self {
            case .allModels: return true
            case .modelPattern(let pattern):
                return Self.glob(pattern.lowercased().replacingOccurrences(of: ".", with: "-"),
                                 modelId.lowercased().replacingOccurrences(of: ".", with: "-"))
            }
        }

        private static func glob(_ pattern: String, _ value: String) -> Bool {
            let parts = pattern.components(separatedBy: "*")
            if parts.count == 1 { return value == pattern }
            var cursor = value.startIndex
            for (index, part) in parts.enumerated() where !part.isEmpty {
                if index == 0 {
                    guard value[cursor...].hasPrefix(part) else { return false }
                    cursor = value.index(cursor, offsetBy: part.count)
                } else if index == parts.count - 1 && !pattern.hasSuffix("*") {
                    guard value[cursor...].hasSuffix(part) else { return false }
                } else if let range = value.range(of: part, range: cursor..<value.endIndex) {
                    cursor = range.upperBound
                } else { return false }
            }
            return true
        }

        var persistedKind: String { if case .modelPattern = self { return "modelPattern" }; return "allModels" }
        var persistedPattern: String? { if case .modelPattern(let value) = self { return value }; return nil }
        static func persisted(kind: String, pattern: String?) -> Scope {
            kind == "modelPattern" && !(pattern ?? "").isEmpty ? .modelPattern(pattern!) : .allModels
        }
        var displayName: String { if case .modelPattern(let value) = self { return value }; return String(localized: "全部模型") }
    }

    enum WireFormat: String, CaseIterable, Identifiable {
        case omit
        case reasoningEffort
        case nestedReasoningEffort
        case deepSeekV4
        case qwenDual
        case booleanToggle
        case extraBodyToggle
        case customPath

        var id: String { rawValue }
        var title: String {
            switch self {
            case .omit: return "不发送思考字段"
            case .reasoningEffort: return "reasoning_effort（根级）"
            case .nestedReasoningEffort: return "reasoning.effort（嵌套）"
            case .deepSeekV4: return "thinking + reasoning_effort"
            case .qwenDual: return "Qwen 思考开关与预算"
            case .booleanToggle: return "布尔开关"
            case .extraBodyToggle: return "extra_body 布尔开关"
            case .customPath: return "自定义字段路径"
            }
        }

        var explanation: String {
            switch self {
            case .omit:
                return "不额外发送思考相关字段。"
            case .reasoningEffort:
                return "在请求根级发送 reasoning_effort，例如 high。"
            case .nestedReasoningEffort:
                return "在 reasoning 对象内发送 effort，例如 reasoning: { effort: high }。"
            case .deepSeekV4:
                return "发送根级 thinking.type 与 reasoning_effort；关闭时仅发送 thinking.type=disabled。"
            case .qwenDual:
                return "同时发送顶级与 extra_body 中的 enable_thinking、thinking_budget，预算会按本次最大输出限制裁剪。"
            case .booleanToggle:
                return "将指定字段发送为 true 或 false。"
            case .extraBodyToggle:
                return "在 extra_body 内将指定字段发送为 true 或 false。"
            case .customPath:
                return "按点分隔的字段路径发送思考强度值。"
            }
        }
    }

    var id: String
    var label: String
    var scope: Scope
    var format: WireFormat
    /// Used by boolean/custom formats. Dot-separated, for example
    /// `extra_body.thinking.enabled`.
    var path: String
    /// Optional explicit value used while thinking is disabled.
    var offValue: String?
    /// A custom-path rule may use a vendor-specific enabled value rather than
    /// the generic reasoning tier (for example `enabled`).
    var customHighValue: String?

    init(id: String = UUID().uuidString, label: String, scope: Scope, format: WireFormat, path: String = "", offValue: String? = nil, customHighValue: String? = nil) {
        self.id = id; self.label = label; self.scope = scope; self.format = format
        self.path = path; self.offValue = offValue; self.customHighValue = customHighValue
    }
}

/// Ze 内建的请求映射目录。它只描述真实的默认行为；点按后会复制为一条
/// 可编辑的自定义规则，因此内建规则本身不会被改写或删除。
struct BuiltInThinkingRule: Identifiable, Equatable {
    let id: String
    let label: String
    let scope: ThinkingRule.Scope
    let summary: String
    let template: ThinkingRule
}

/// Lock-protected snapshot read from the synchronous request builder.
final class ThinkingRuleCache: @unchecked Sendable {
    static let shared = ThinkingRuleCache()
    private let lock = NSLock()
    private var values: [String: [ThinkingRule]] = [:]
    func replace(_ rules: [ThinkingRule], for instanceId: String) { lock.lock(); values[instanceId] = rules; lock.unlock() }
    func rules(for instanceId: String?) -> [ThinkingRule] {
        guard let instanceId else { return [] }
        lock.lock(); defer { lock.unlock() }; return values[instanceId] ?? []
    }
}

enum ThinkingRuleResolver {

    /// Build Gemini's native generationConfig.thinkingConfig shape. Gemini
    /// uses model-family-specific fields rather than OpenAI's reasoning_effort.
    /// Specialized output models are checked first because their IDs can also
    /// contain a Gemini family marker while rejecting thinkingConfig entirely.
    static func geminiThinkingConfig(modelId: String, level: ThinkingLevel) -> [String: Any] {
        let id = modelId.lowercased()
        let specialized = ["-tts", "-image", "-embedding", "-vision"]
        if specialized.contains(where: { id.hasSuffix($0) || id.contains("\($0)-") }) { return [:] }

        if level.isEnabled {
            if id.contains("gemini-3") {
                let geminiLevel: String
                switch level {
                case .off: geminiLevel = "minimal"
                case .low: geminiLevel = "low"
                case .medium: geminiLevel = "medium"
                case .high, .xhigh, .max, .ultra: geminiLevel = "high"
                }
                return ["thinkingLevel": geminiLevel, "includeThoughts": true]
            }
            if id.contains("2.5-pro") {
                let budget: Int = switch level {
                case .off: 128
                case .low: 2048
                case .medium: 8192
                case .high: 16384
                case .xhigh, .max, .ultra: 32768
                }
                return ["thinkingBudget": budget, "includeThoughts": true]
            }
            if id.contains("2.5-flash") && !id.contains("lite") {
                let budget: Int = switch level {
                case .off: 0
                case .low: 1024
                case .medium: 4096
                case .high: 8192
                case .xhigh, .max, .ultra: 16384
                }
                return ["thinkingBudget": budget, "includeThoughts": true]
            }
            let budget: Int = switch level {
            case .off: 128
            case .low: 1024
            case .medium: 4096
            case .high: 8192
            case .xhigh, .max, .ultra: 16384
            }
            return ["thinkingBudget": budget, "includeThoughts": true]
        }

        if id.contains("gemini-3") {
            let flashAcceptsMinimal = id.contains("flash") && (geminiMinorVersion(id).map { $0 < 7 } ?? true)
            return ["thinkingLevel": flashAcceptsMinimal ? "minimal" : "low"]
        }
        if id.contains("2.5-pro") { return ["thinkingBudget": 128] }
        if id.contains("2.5-flash-lite") { return [:] }
        return ["thinkingBudget": 0]
    }

    private static func geminiMinorVersion(_ id: String) -> Int? {
        guard let range = id.range(of: #"gemini-\d+\.\d+"#, options: .regularExpression),
              let dot = id[range].lastIndex(of: ".") else { return nil }
        return Int(id[id.index(after: dot)..<range.upperBound])
    }
    @MainActor
    static func builtInRulesForDisplay(instanceId: String) -> [BuiltInThinkingRule] {
        guard let instance = ProviderConfigStore.shared.instance(for: instanceId) else { return [] }
        let modelIds = ProviderConfigStore.shared.modelEntries
            .filter { $0.providerInstanceId == instanceId && !$0.isHidden }
            .map { $0.model.id }
        let baseURL = instance.effectiveCustomBaseURL?.lowercased() ?? ""
        let isOpenRouter = instance.providerType == .openRouter || baseURL.contains("openrouter.ai")
        let isMistral = baseURL.contains("mistral.ai") || modelIds.contains { $0.lowercased().contains("mistral") }
        let isUnifiedGateway = instance.azureMode || baseURL.contains("volces") || baseURL.contains("ark.") || baseURL.contains("azure") || baseURL.contains("venice.ai")

        func rule(_ id: String, _ label: String, _ scope: ThinkingRule.Scope, _ format: ThinkingRule.WireFormat, _ summary: String, path: String = "", offValue: String? = nil) -> BuiltInThinkingRule {
            BuiltInThinkingRule(
                id: id,
                label: label,
                scope: scope,
                summary: summary,
                template: ThinkingRule(label: label, scope: scope, format: format, path: path, offValue: offValue)
            )
        }

        var candidates: [BuiltInThinkingRule] = []
        if isMistral {
            candidates.append(rule("mistral-official", "Mistral 默认规则", .allModels, .omit, "Mistral 接口不额外发送思考字段"))
        } else if isOpenRouter {
            candidates.append(rule("openrouter-default", "OpenRouter 默认规则", .allModels, .nestedReasoningEffort, "发送 reasoning.effort"))
        } else {
            let openAIModels = ["o1*", "o3*", "o4*", "gpt-5*", "gpt-4*"]
            for pattern in openAIModels {
                candidates.append(rule("openai-\(pattern)", "OpenAI \(pattern)", .modelPattern(pattern), .reasoningEffort, "发送 reasoning_effort"))
            }
            candidates.append(rule("qwen-thinking", "Qwen 思考规则", .modelPattern("*qwen*"), .qwenDual, "发送 enable_thinking 与 thinking_budget"))
            if isUnifiedGateway {
                candidates.append(rule("unified-gateway-default", "统一网关默认规则", .allModels, .reasoningEffort, "发送 reasoning_effort"))
            } else {
                candidates.append(rule("deepseek-v4-official", "DeepSeek V4 官方规则", .modelPattern("*deepseek-v4*"), .deepSeekV4, "发送 thinking 与 reasoning_effort"))
            }
        }
        candidates.append(rule("openai-compatible-default", "OpenAI 兼容默认规则", .allModels, .reasoningEffort, "发送 reasoning_effort"))

        // 有模型时只展示此服务商实际可能命中的规则；首次配置尚未拉取模型时
        // 保留候选规则，避免用户面对一个空白目录。
        guard !modelIds.isEmpty else { return candidates }
        return candidates.filter { candidate in
            if case .allModels = candidate.scope { return true }
            return modelIds.contains { candidate.scope.matches($0) }
        }
    }

    static func requestPreview(for rule: ThinkingRule, level: ThinkingLevel = .high) -> String {
        var body: [String: Any] = ["model": "示例模型", "messages": [["role": "user", "content": "你好"]]]
        apply(rule: rule, to: &body, level: level, maxTokens: 4096)
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body, options: [.prettyPrinted, .sortedKeys]),
              let text = String(data: data, encoding: .utf8) else { return "{}" }
        return text
    }

    /// Returns true if a custom rule matched. The caller must skip legacy built-in
    /// branching in that case, including for `.omit`.
    static func applyCustomRule(to body: inout [String: Any], instanceId: String?, modelId: String, level: ThinkingLevel, maxTokens: Int = 0) -> Bool {
        guard let rule = ThinkingRuleCache.shared.rules(for: instanceId).first(where: { $0.scope.matches(modelId) }) else { return false }
        apply(rule: rule, to: &body, level: level, maxTokens: maxTokens)
        return true
    }

    private static func apply(rule: ThinkingRule, to body: inout [String: Any], level: ThinkingLevel, maxTokens: Int) {
        let value = effort(level)
        switch rule.format {
        case .omit:
            break
        case .reasoningEffort:
            if level.isEnabled { body["reasoning_effort"] = value }
            else if let off = rule.offValue, !off.isEmpty { body["reasoning_effort"] = off }
        case .nestedReasoningEffort:
            if level.isEnabled { body["reasoning"] = ["effort": value] }
            else if let off = rule.offValue, !off.isEmpty { body["reasoning"] = ["effort": off] }
        case .deepSeekV4:
            // DeepSeek V4's switch and effort are root siblings. Nesting the
            // effort inside `thinking` is silently ignored by the current API.
            body["thinking"] = ["type": level.isEnabled ? "enabled" : "disabled"]
            if level.isEnabled { body["reasoning_effort"] = value }
        case .qwenDual:
            body["enable_thinking"] = level.isEnabled
            var budget: Int = switch level {
            case .off: 0
            case .low: 4096
            case .medium: 16384
            case .high: 32768
            case .xhigh, .max, .ultra: 65536
            }
            if budget > 0 && maxTokens > 0 {
                if maxTokens < 2 { budget = 0 }
                else {
                    let margin = max(2048, maxTokens / 8)
                    let ceiling = max(1, min(maxTokens - margin, maxTokens - 1))
                    if budget >= ceiling { budget = ceiling }
                }
            }
            if budget > 0 { body["thinking_budget"] = budget }
            body["extra_body"] = [
                "enable_thinking": level.isEnabled,
                "thinking_budget": budget > 0 ? budget : NSNull(),
            ] as [String: Any]
        case .booleanToggle:
            set(path: rule.path.isEmpty ? "thinking" : rule.path, value: level.isEnabled, in: &body)
        case .extraBodyToggle:
            let path = rule.path.isEmpty ? "extra_body.thinking.enabled" : rule.path
            set(path: path, value: level.isEnabled, in: &body)
        case .customPath:
            if level.isEnabled { set(path: rule.path, value: rule.customHighValue?.isEmpty == false ? rule.customHighValue! : value, in: &body) }
            else if let off = rule.offValue, !off.isEmpty { set(path: rule.path, value: off, in: &body) }
        }
    }

    static func effort(_ level: ThinkingLevel) -> String {
        switch level {
        case .off, .low: return "low"
        case .medium: return "medium"
        case .high: return "high"
        case .xhigh: return "xhigh"
        case .max, .ultra: return "max"
        }
    }

    private static func set(path: String, value: Any, in body: inout [String: Any]) {
        let parts = path.split(separator: ".").map(String.init).filter { !$0.isEmpty }
        guard let first = parts.first else { return }
        func inserting(_ index: Int, into object: [String: Any]) -> [String: Any] {
            var result = object
            if index == parts.count - 1 { result[parts[index]] = value }
            else {
                result[parts[index]] = inserting(index + 1, into: result[parts[index]] as? [String: Any] ?? [:])
            }
            return result
        }
        body = inserting(0, into: body)
        _ = first
    }
}
