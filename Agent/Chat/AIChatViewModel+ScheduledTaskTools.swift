import Foundation

/// Agent-facing scheduling tools. They operate on the same main-actor store as
/// the Settings UI, so model-created schedules immediately appear in Settings,
/// persist atomically, and acquire the same Live Activity ownership lease.
extension AIChatViewModel {
    struct ScheduledTaskAgentToolResult {
        let output: String
        let success: Bool
    }

    func scheduledTaskAgentToolDefinitions() -> [AgentToolDefinition] {
        [
            AgentToolDefinition(
                name: "scheduled_task_create",
                description: "Create and enable a persistent scheduled task in Ze. Use this when the user asks Ze to remember a prompt and run it later or repeatedly. The task appears in Settings > Scheduled Tasks and can run in the current conversation or a new conversation. Use the current selected model by default; never invent a model_entry_id.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise summary shown in the tool timeline."),
                    "task_name": AgentToolParam(type: .string, description: "Short name displayed in the scheduled-task list."),
                    "prompt": AgentToolParam(type: .string, description: "The exact prompt to send to the model at each run."),
                    "repeat_rule": AgentToolParam(type: .string, description: "Repeat rule: daily, weekly, monthly, or once.", enumValues: ["daily", "weekly", "monthly", "once"]),
                    "hour": AgentToolParam(type: .integer, description: "Local hour 0-23. Defaults to 8."),
                    "minute": AgentToolParam(type: .integer, description: "Local minute 0-59. Defaults to 0."),
                    "scheduled_at": AgentToolParam(type: .string, description: "Required for once: ISO-8601 local-date/time or date string, for example 2026-10-08T09:30:00+08:00."),
                    "weekday": AgentToolParam(type: .integer, description: "For weekly: Calendar weekday 1=Sunday through 7=Saturday."),
                    "month_day": AgentToolParam(type: .integer, description: "For monthly: day of month 1-31; the last day is clamped automatically."),
                    "end_date": AgentToolParam(type: .string, description: "Optional ISO-8601 date after which recurring runs stop."),
                    "run_mode": AgentToolParam(type: .string, description: "currentConversation uses this conversation; newConversation creates a background conversation.", enumValues: ["currentConversation", "newConversation"]),
                    "model_entry_id": AgentToolParam(type: .string, description: "Optional configured model entry ID. Omit to use the currently selected model."),
                ],
                required: ["tool_title", "task_name", "prompt", "repeat_rule"],
                propertyOrdering: ["tool_title", "task_name", "prompt", "repeat_rule", "scheduled_at", "hour", "minute", "weekday", "month_day", "end_date", "run_mode", "model_entry_id"]
            ),
            AgentToolDefinition(
                name: "scheduled_task_list",
                description: "List persistent scheduled tasks and their next run times. Does not reveal credentials or prompt contents beyond a short preview.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise summary shown in the tool timeline.")
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "scheduled_task_set_enabled",
                description: "Enable or disable an existing scheduled task by ID. Disabling cancels its current execution and releases its Live Activity lease.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise summary shown in the tool timeline."),
                    "id": AgentToolParam(type: .string, description: "Scheduled task UUID from scheduled_task_list or scheduled_task_create."),
                    "enabled": AgentToolParam(type: .boolean, description: "Whether to keep scheduling this task."),
                ],
                required: ["tool_title", "id", "enabled"],
                propertyOrdering: ["tool_title", "id", "enabled"]
            ),
            AgentToolDefinition(
                name: "scheduled_task_delete",
                description: "Delete an existing scheduled task by ID and cancel its current execution. This does not delete the conversation or its run history.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "A concise summary shown in the tool timeline."),
                    "id": AgentToolParam(type: .string, description: "Scheduled task UUID from scheduled_task_list or scheduled_task_create."),
                ],
                required: ["tool_title", "id"],
                propertyOrdering: ["tool_title", "id"]
            )
        ]
    }

    func executeScheduledTaskAgentTool(name: String, arguments: [String: Any]) -> ScheduledTaskAgentToolResult {
        let store = ScheduledTaskStore.shared
        do {
            switch name {
            case "scheduled_task_create":
                var task = ScheduledTaskDefinition()
                task.name = string(arguments, "task_name")
                task.prompt = string(arguments, "prompt")
                guard let repeatRule = ScheduledTaskRepeat(rawValue: string(arguments, "repeat_rule")) else {
                    return .init(output: "创建失败：repeat_rule 必须是 daily、weekly、monthly 或 once。", success: false)
                }
                task.repeatRule = repeatRule
                task.hour = integer(arguments, "hour", default: 8)
                task.minute = integer(arguments, "minute", default: 0)
                task.weekday = integer(arguments, "weekday", default: Calendar.current.component(.weekday, from: Date()))
                task.monthDay = integer(arguments, "month_day", default: Calendar.current.component(.day, from: Date()))
                guard let runMode = ScheduledTaskRunMode(rawValue: string(arguments, "run_mode", default: "newConversation")) else {
                    return .init(output: "创建失败：run_mode 必须是 currentConversation 或 newConversation。", success: false)
                }
                task.runMode = runMode
                task.sessionId = task.runMode == .currentConversation ? sessionId : nil
                let entryID = string(arguments, "model_entry_id")
                guard let entry = entryID.isEmpty ? resolveCurrentEntry() : ProviderConfigStore.shared.entry(for: entryID) else {
                    return .init(output: "创建失败：没有可用的当前模型。请先在设置中配置并启用一个支持文本输出的模型。", success: false)
                }
                task.modelEntryId = entry.id
                if task.repeatRule == .once {
                    guard let scheduledAt = parseDate(arguments["scheduled_at"] as? String) else {
                        return .init(output: "创建失败：一次性任务必须提供 scheduled_at（ISO-8601 日期时间）。", success: false)
                    }
                    task.oneTimeDate = scheduledAt
                    let comps = Calendar.current.dateComponents([.hour, .minute], from: scheduledAt)
                    task.hour = comps.hour ?? task.hour
                    task.minute = comps.minute ?? task.minute
                }
                if let endDate = parseDate(arguments["end_date"] as? String) { task.endDate = endDate }
                if let enabled = arguments["enabled"] as? Bool { task.isEnabled = enabled }
                try store.save(task)
                let next = task.nextRunAt?.formatted(date: .complete, time: .shortened) ?? "未安排"
                return .init(output: "已创建定时任务：\(task.displayName)\n任务ID：\(task.id.uuidString)\n下次执行：\(next)\n运行方式：\(task.runMode == .currentConversation ? "当前对话" : "新建对话")\n模型：\(entry.model.id)", success: true)

            case "scheduled_task_list":
                let lines = store.tasks.sorted { ($0.nextRunAt ?? .distantFuture) < ($1.nextRunAt ?? .distantFuture) }.map { task in
                    let next = task.nextRunAt?.formatted(date: .complete, time: .shortened) ?? "无下一次执行"
                    return "- \(task.displayName) | id=\(task.id.uuidString) | \(task.isEnabled ? "已启用" : "已停用") | \(next)"
                }
                return .init(output: lines.isEmpty ? "当前没有定时任务。" : lines.joined(separator: "\n"), success: true)

            case "scheduled_task_set_enabled":
                guard let id = UUID(uuidString: string(arguments, "id")), store.tasks.contains(where: { $0.id == id }) else {
                    return .init(output: "操作失败：找不到这个定时任务ID。", success: false)
                }
                let enabled = (arguments["enabled"] as? Bool) ?? false
                try store.setEnabled(id: id, enabled: enabled)
                return .init(output: "已\(enabled ? "启用" : "停用")定时任务：\(id.uuidString)", success: true)

            case "scheduled_task_delete":
                guard let id = UUID(uuidString: string(arguments, "id")), store.tasks.contains(where: { $0.id == id }) else {
                    return .init(output: "操作失败：找不到这个定时任务ID。", success: false)
                }
                try store.delete(id: id)
                return .init(output: "已删除定时任务：\(id.uuidString)。运行记录和关联对话仍保留。", success: true)

            default:
                return .init(output: "未知定时任务操作。", success: false)
            }
        } catch {
            return .init(output: "定时任务操作失败：\(error.localizedDescription)", success: false)
        }
    }

    private func string(_ args: [String: Any], _ key: String, default fallback: String = "") -> String {
        (args[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? fallback
    }

    private func integer(_ args: [String: Any], _ key: String, default fallback: Int) -> Int {
        if let value = args[key] as? Int { return value }
        if let value = args[key] as? NSNumber { return value.intValue }
        return fallback
    }

    private func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: raw) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: raw) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: raw)
    }
}
