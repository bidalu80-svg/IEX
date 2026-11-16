import Foundation

/// Settings shared by the sub-agent settings page and the agent tools.
///
/// `subAgentThinkingEnabled` is intentionally tri-state on disk:
/// - key absent  → keep the pre-upgrade behaviour (inherit the default primary
///                 group's thinking level, or `.off` when that group has none);
/// - key present → the user (or a tool after confirmation) made an explicit
///                 choice: on = medium, off = off.
///
/// That absence check is what prevents an App Store upgrade from changing the
/// thinking behaviour of an existing child agent.
///
/// Baseline measurement (HEAD 7b65a4d, production path): `spawn` never writes a
/// child inference config; the first `send` reaches `ensureSessionReturningId`
/// → `createInitialBinding` → `applyGroupSessionDefaults`, which copies the
/// default primary group's `defaultThinkingLevel`. The migration/default-group
/// builders create groups with `nil`, so the request path then falls back to
/// `.off`. Absence must therefore mean "leave that legacy path alone", not
/// "write off".
@MainActor
enum ZeSubAgentThinkingSettings {
    static var explicitEnabled: Bool? {
        guard let number = UserDefaults.standard.object(forKey: ZeSubAgentPreferences.thinkingEnabledKey) as? NSNumber else {
            return nil
        }
        return number.boolValue
    }

    static var explicitLevel: ThinkingLevel? {
        guard let enabled = explicitEnabled else { return nil }
        return enabled ? .medium : .off
    }

    /// Effective value shown by the settings page and returned by the get tool.
    static var resolvedEnabled: Bool {
        if let enabled = explicitEnabled { return enabled }
        return defaultGroupLevel?.isEnabled ?? false
    }

    /// Effective level before model clamping. `.off` is used for legacy children
    /// whose default group has no explicit default thinking level, matching the
    /// pre-upgrade request path.
    static var effectiveLevel: ThinkingLevel {
        if let level = explicitLevel { return level }
        return defaultGroupLevel ?? .off
    }

    static func setEnabled(_ enabled: Bool) {
        UserDefaults.standard.set(enabled, forKey: ZeSubAgentPreferences.thinkingEnabledKey)
    }

    private static var defaultGroupLevel: ThinkingLevel? {
        let store = ProviderConfigStore.shared
        guard let groupId = store.defaultPrimaryGroupId,
              let group = store.group(for: groupId) else { return nil }
        return group.defaultThinkingLevel
    }
}

/// The exact model filter used by both the picker and the agent tools, so the
/// two surfaces can never disagree about which model ids are selectable.
@MainActor
enum ZeSubAgentModelCatalog {
    static func availableEntries() -> [ModelEntry] {
        let store = ProviderConfigStore.shared
        return store.modelEntries.filter { entry in
            guard !entry.isHidden,
                  let instance = store.instance(for: entry.providerInstanceId) else { return false }
            return instance.isEnabled && instance.hasAnyCredential
        }
    }

    static func providerLabel(for entry: ModelEntry) -> String {
        ProviderConfigStore.shared.instance(for: entry.providerInstanceId)?.label ?? entry.model.provider
    }

    static func jsonRows() -> [[String: Any]] {
        availableEntries().map { entry in
            [
                "entry_id": entry.id,
                "model_id": entry.model.id,
                "model_name": entry.model.displayName,
                "provider_name": providerLabel(for: entry),
            ]
        }
    }
}

struct SubAgentAIToolResult {
    let output: String
    let success: Bool
}

/// Read/write access to the sub-agent model pin and thinking switch.
///
/// Writes go through the same UserDefaults keys as `SubAgentSettingsView`;
/// there is deliberately no second configuration store.
@MainActor
enum SubAgentAIToolGateway {
    static func definitions() -> [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "subagent_config_get",
                description: "读取当前子代理配置：执行模型（跟随当前对话或具体模型）、思考开关，以及可用模型清单（entry id、模型名、服务商名）。只读操作，不修改设置。",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "显示给用户的简短操作标题"),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "subagent_config_set",
                description: "修改子代理配置。model 传 subagent_config_get 清单中的 entry id，或 follow 表示跟随当前对话；thinking 传 true/false。两项可只改一项。写入与设置页相同的 UserDefaults；执行前会请用户确认。传不存在的模型 id 会被拒绝并回带可用清单。",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "显示给用户的简短操作标题"),
                    "model": AgentToolParam(type: .string, description: "可用清单中的 entry id，或 follow / 留空表示跟随当前对话。"),
                    "thinking": AgentToolParam(type: .boolean, description: "子代理思考开关：true 开启（中等档），false 关闭。"),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title", "model", "thinking"]
            ),
        ]
    }

    static func execute(name: String, arguments: [String: Any]) async -> SubAgentAIToolResult {
        switch name {
        case "subagent_config_get":
            return .init(output: getOutput(), success: true)
        case "subagent_config_set":
            return await setConfiguration(arguments)
        default:
            return .init(output: "未知子代理配置操作。", success: false)
        }
    }

    private static func getOutput() -> String {
        let store = ProviderConfigStore.shared
        let reference = ZeSubAgentPreferences.configuredModelEntryReference
        let entry = reference.flatMap { store.entry(for: $0) }

        var model: [String: Any] = ["mode": entry == nil ? "follow" : "entry"]
        if let entry {
            model["entry_id"] = entry.id
            model["model_id"] = entry.model.id
            model["model_name"] = entry.model.displayName
            model["provider_name"] = ZeSubAgentModelCatalog.providerLabel(for: entry)
        }
        if let reference, entry == nil {
            // A stale id should be visible instead of silently pretending to
            // follow the conversation model.
            model["stale_entry_id"] = reference
        }

        let explicit = ZeSubAgentThinkingSettings.explicitEnabled
        let payload: [String: Any] = [
            "model": model,
            "thinking_enabled": ZeSubAgentThinkingSettings.resolvedEnabled,
            "thinking_level": ZeSubAgentThinkingSettings.effectiveLevel.rawValue,
            "thinking_source": explicit == nil ? "default_group" : "subagent_setting",
            "available_models": ZeSubAgentModelCatalog.jsonRows(),
        ]
        return json(payload)
    }

    private static func setConfiguration(_ arguments: [String: Any]) async -> SubAgentAIToolResult {
        let hasModel = arguments["model"] != nil && !(arguments["model"] is NSNull)
        let hasThinking = arguments["thinking"] != nil && !(arguments["thinking"] is NSNull)
        guard hasModel || hasThinking else {
            return .init(output: "修改失败：model 与 thinking 至少提供一项。可先调用 subagent_config_get 查看当前配置和可用模型。", success: false)
        }

        let store = ProviderConfigStore.shared
        var targetEntry: ModelEntry?
        var clearModel = false
        if hasModel {
            let raw = (arguments["model"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            if raw.isEmpty || raw.lowercased() == "follow" {
                clearModel = true
            } else if let entry = store.entry(for: raw),
                      ZeSubAgentModelCatalog.availableEntries().contains(where: { $0.id == entry.id }) {
                targetEntry = entry
            } else {
                let rows = ZeSubAgentModelCatalog.jsonRows()
                return .init(output: "修改失败：模型 id“\(raw)”不在可用清单中。请从以下 entry id 中选择，或传 follow：\n\(json(["available_models": rows]))", success: false)
            }
        }

        var thinkingValue: Bool?
        if hasThinking {
            if let value = arguments["thinking"] as? Bool {
                thinkingValue = value
            } else if let value = arguments["thinking"] as? NSNumber {
                thinkingValue = value.boolValue
            } else {
                return .init(output: "修改失败：thinking 必须是 true 或 false。", success: false)
            }
        }

        var changes: [String] = []
        if let targetEntry {
            changes.append("模型：\(targetEntry.model.displayName)（\(ZeSubAgentModelCatalog.providerLabel(for: targetEntry))）")
        } else if clearModel {
            changes.append("模型：跟随当前对话")
        }
        if let thinkingValue {
            changes.append("思考：\(thinkingValue ? "开启（中等档）" : "关闭")")
        }

        let approved = await RemoteServerAIConfirmationGate.shared.request(
            serverName: "Ze 子代理设置",
            operation: "修改子代理配置",
            detail: changes.joined(separator: "\n"),
            isDestructive: false
        )
        guard approved else {
            return .init(output: "用户拒绝了子代理配置修改。除非用户再次明确要求，不要重试。", success: false)
        }

        if clearModel {
            UserDefaults.standard.removeObject(forKey: ZeSubAgentPreferences.modelEntryKey)
        } else if let targetEntry {
            UserDefaults.standard.set(targetEntry.id, forKey: ZeSubAgentPreferences.modelEntryKey)
        }
        if let thinkingValue {
            ZeSubAgentThinkingSettings.setEnabled(thinkingValue)
        }

        let appliedModel: String = {
            if clearModel { return "follow" }
            if let targetEntry { return targetEntry.id }
            return ZeSubAgentPreferences.configuredModelEntryReference ?? "follow"
        }()
        let applied: [String: Any] = [
            "success": true,
            "model": appliedModel,
            "thinking": thinkingValue ?? ZeSubAgentThinkingSettings.resolvedEnabled,
        ]
        return .init(output: json(applied), success: true)
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"无法编码结果\"}"
        }
        return text
    }
}
