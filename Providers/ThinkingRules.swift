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
        case booleanToggle
        case customPath

        var id: String { rawValue }
        var title: String {
            switch self {
            case .omit: return "不发送思考字段"
            case .reasoningEffort: return "推理强度字段"
            case .nestedReasoningEffort: return "嵌套推理强度字段"
            case .booleanToggle: return "布尔开关"
            case .customPath: return "自定义字段路径"
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

    init(id: String = UUID().uuidString, label: String, scope: Scope, format: WireFormat, path: String = "", offValue: String? = nil) {
        self.id = id; self.label = label; self.scope = scope; self.format = format
        self.path = path; self.offValue = offValue
    }
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
    /// Returns true if a custom rule matched. The caller must skip legacy built-in
    /// branching in that case, including for `.omit`.
    static func applyCustomRule(to body: inout [String: Any], instanceId: String?, modelId: String, level: ThinkingLevel) -> Bool {
        guard let rule = ThinkingRuleCache.shared.rules(for: instanceId).first(where: { $0.scope.matches(modelId) }) else { return false }
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
        case .booleanToggle:
            set(path: rule.path.isEmpty ? "thinking" : rule.path, value: level.isEnabled, in: &body)
        case .customPath:
            if level.isEnabled { set(path: rule.path, value: value, in: &body) }
            else if let off = rule.offValue, !off.isEmpty { set(path: rule.path, value: off, in: &body) }
        }
        return true
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
