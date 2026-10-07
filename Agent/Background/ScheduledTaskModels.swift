import Foundation

enum ScheduledTaskRepeat: String, Codable, CaseIterable {
    case daily, weekly, monthly, once
}

enum ScheduledTaskRunMode: String, Codable, CaseIterable {
    case currentConversation, newConversation
}

/// Local wall-clock schedules follow the device's current calendar/time zone.
/// Monthly dates clamp to the last day; DST gaps move forward, folds fire once.
struct ScheduledTaskDefinition: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var prompt = ""
    var repeatRule: ScheduledTaskRepeat = .daily
    var hour = 8
    var minute = 0
    var weekday = Calendar.current.component(.weekday, from: Date())
    var monthDay = Calendar.current.component(.day, from: Date())
    var oneTimeDate = Date()
    var endDate: Date?
    var runMode: ScheduledTaskRunMode = .newConversation
    var sessionId: String?
    var modelEntryId = ""
    var isEnabled = true
    var nextRunAt: Date?
    var createdAt = Date()

    var displayName: String {
        let title = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? String(prompt.trimmingCharacters(in: .whitespacesAndNewlines).prefix(30)) : title
    }

    func isExpired(at date: Date, calendar: Calendar = .current) -> Bool {
        guard let endDate else { return false }
        return calendar.startOfDay(for: date) > calendar.startOfDay(for: endDate)
    }

    func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute),
              (1...7).contains(weekday), (1...31).contains(monthDay),
              !isExpired(at: date, calendar: calendar) else { return nil }
        let firstDay = calendar.startOfDay(for: repeatRule == .once ? oneTimeDate : date)
        for offset in 0..<(repeatRule == .once ? 1 : 400) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: firstDay) else { continue }
            if isExpired(at: day, calendar: calendar) { return nil }
            if repeatRule == .weekly && calendar.component(.weekday, from: day) != weekday { continue }
            if repeatRule == .monthly {
                guard let range = calendar.range(of: .day, in: .month, for: day),
                      calendar.component(.day, from: day) == min(monthDay, range.count) else { continue }
            }
            guard let candidate = calendar.date(bySettingHour: hour, minute: minute, second: 0,
                                                of: day, matchingPolicy: .nextTime,
                                                repeatedTimePolicy: .first, direction: .forward),
                  calendar.isDate(candidate, inSameDayAs: day), candidate > date else { continue }
            return candidate
        }
        return nil
    }
}

enum ScheduledTaskRunStatus: String, Codable {
    case running, succeeded, failed, interrupted
}

struct ScheduledTaskRun: Codable, Identifiable {
    var id = UUID()
    var taskId: UUID
    var taskName: String
    var scheduledAt: Date
    var startedAt: Date
    var finishedAt: Date?
    var status: ScheduledTaskRunStatus = .running
    var sessionId: String?
    var summary = ""
    var error: String?
}

struct ScheduledTaskSnapshot: Codable {
    var version = 1
    var tasks: [ScheduledTaskDefinition] = []
    var runs: [ScheduledTaskRun] = []

    mutating func recoverInterruptedRuns(at date: Date) {
        for index in runs.indices where runs[index].status == .running {
            runs[index].status = .interrupted
            runs[index].finishedAt = date
            runs[index].error = String(localized: "上次运行因应用退出而中断，未自动重试。")
        }
    }

    @discardableResult
    mutating func claim(taskID: UUID, at date: Date) -> ScheduledTaskRun? {
        guard let index = tasks.firstIndex(where: { $0.id == taskID }), tasks[index].isEnabled,
              let due = tasks[index].nextRunAt, due <= date, !tasks[index].isExpired(at: date),
              !runs.contains(where: { $0.taskId == taskID && $0.status == .running }) else { return nil }
        let task = tasks[index]
        let record = ScheduledTaskRun(taskId: task.id, taskName: task.displayName, scheduledAt: due, startedAt: date)
        tasks[index].nextRunAt = task.repeatRule == .once ? nil : task.nextOccurrence(after: date)
        if tasks[index].nextRunAt == nil { tasks[index].isEnabled = false }
        runs.insert(record, at: 0)
        return record
    }
}

/// One atomic file contains both occurrence claims and definitions. A crash can
/// leave an interrupted run, but never an unclaimed prompt that auto-replays.
struct ScheduledTaskRepository {
    let fileURL: URL

    func load() throws -> ScheduledTaskSnapshot {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return ScheduledTaskSnapshot() }
        let snapshot = try JSONDecoder().decode(ScheduledTaskSnapshot.self, from: Data(contentsOf: fileURL))
        guard snapshot.version == 1 else { throw ScheduledTaskError.unsupportedVersion }
        return snapshot
    }

    func write(_ snapshot: ScheduledTaskSnapshot) throws {
        try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(snapshot)
        try data.write(to: fileURL, options: .atomic)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication],
                                             ofItemAtPath: fileURL.path)
        #endif
    }
}

enum ScheduledTaskError: LocalizedError {
    case invalidPrompt, invalidModel, invalidSession, invalidSchedule, unsupportedVersion, storageUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidPrompt: return String(localized: "请输入任务提示词。")
        case .invalidModel: return String(localized: "请选择已启用且已配置凭据的服务商模型。")
        case .invalidSession: return String(localized: "当前对话已不存在，请选择新建对话。")
        case .invalidSchedule: return String(localized: "此时间设置没有下一次运行时间，请检查日期和到期日期。")
        case .unsupportedVersion: return String(localized: "定时任务数据版本较新，请升级应用后再试。")
        case .storageUnavailable: return String(localized: "定时任务数据读取异常，原文件已保留。请检查存储空间后重新启动应用。")
        }
    }
}

/// Immutable per-turn result; a later user turn must never rewrite this outcome.
struct ScheduledTaskTurnResult {
    var status: ScheduledTaskRunStatus
    var summary: String
    var error: String?
}

struct ScheduledTaskCompletionLatch {
    private(set) var result: ScheduledTaskTurnResult?

    @discardableResult
    mutating func finish(_ value: ScheduledTaskTurnResult) -> Bool {
        guard result == nil else { return false }
        result = value
        return true
    }
}
