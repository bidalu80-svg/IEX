// Standalone tests run with macOS Foundation before the full iOS build.
import Foundation

@main
struct ScheduledTaskTests {
    static var count = 0
    static func check(_ condition: @autoclosure () -> Bool, _ name: String) {
        guard condition() else { fatalError("FAIL: \(name)") }
        count += 1
        print("PASS: \(name)")
    }
    static func date(_ text: String) -> Date { ISO8601DateFormatter().date(from: text)! }
    static func main() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(secondsFromGMT: 0)!
        var task = ScheduledTaskDefinition()
        task.prompt = "每日工作摘要"
        task.modelEntryId = "provider/model"
        check(task.hour == 8 && task.minute == 0, "default 08:00")
        check(task.nextOccurrence(after: date("2026-10-07T07:59:00Z"), calendar: utc) == date("2026-10-07T08:00:00Z"), "daily today")
        check(task.nextOccurrence(after: date("2026-10-07T08:00:00Z"), calendar: utc) == date("2026-10-08T08:00:00Z"), "strictly after boundary, no duplicate")
        task.repeatRule = .weekly; task.weekday = 2
        check(task.nextOccurrence(after: date("2026-10-07T10:00:00Z"), calendar: utc) == date("2026-10-12T08:00:00Z"), "weekly Monday")
        check(task.nextOccurrence(after: date("2026-10-12T08:00:00Z"), calendar: utc) == date("2026-10-19T08:00:00Z"), "weekly next week")
        task.repeatRule = .monthly; task.monthDay = 31
        check(task.nextOccurrence(after: date("2026-04-01T00:00:00Z"), calendar: utc) == date("2026-04-30T08:00:00Z"), "monthly clamp to day 30")
        check(task.nextOccurrence(after: date("2026-02-01T00:00:00Z"), calendar: utc) == date("2026-02-28T08:00:00Z"), "monthly non-leap February")
        check(task.nextOccurrence(after: date("2028-02-01T00:00:00Z"), calendar: utc) == date("2028-02-29T08:00:00Z"), "monthly leap February")
        task.monthDay = 1
        check(task.nextOccurrence(after: date("2026-12-31T10:00:00Z"), calendar: utc) == date("2027-01-01T08:00:00Z"), "year rollover")
        task.repeatRule = .once; task.oneTimeDate = date("2026-10-10T00:00:00Z")
        check(task.nextOccurrence(after: date("2026-10-07T10:00:00Z"), calendar: utc) == date("2026-10-10T08:00:00Z"), "one-time chosen date")
        check(task.nextOccurrence(after: date("2026-10-10T08:00:00Z"), calendar: utc) == nil, "one-time does not recur")
        task.repeatRule = .daily; task.endDate = date("2026-10-07T00:00:00Z")
        check(task.nextOccurrence(after: date("2026-10-07T07:00:00Z"), calendar: utc) == date("2026-10-07T08:00:00Z"), "expiry includes entire selected day")
        check(task.nextOccurrence(after: date("2026-10-07T08:00:00Z"), calendar: utc) == nil, "no run after expiry")
        check(task.isExpired(at: date("2026-10-08T00:00:00Z"), calendar: utc), "expiry next midnight")
        task.endDate = nil; task.hour = 24
        check(task.nextOccurrence(after: Date(), calendar: utc) == nil, "invalid hour rejected")
        task.hour = 8; task.minute = -1
        check(task.nextOccurrence(after: Date(), calendar: utc) == nil, "invalid minute rejected")
        task.minute = 0; task.weekday = 0
        check(task.nextOccurrence(after: Date(), calendar: utc) == nil, "invalid weekday rejected")
        task.weekday = 2; task.monthDay = 32
        check(task.nextOccurrence(after: Date(), calendar: utc) == nil, "invalid month day rejected")
        task.monthDay = 1
        var la = utc; la.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        task.hour = 2; task.minute = 30
        check(task.nextOccurrence(after: date("2026-03-08T08:00:00Z"), calendar: la) == date("2026-03-08T10:00:00Z"), "DST missing 02:30 advances to 03:00")
        task.hour = 1
        check(task.nextOccurrence(after: date("2026-11-01T07:00:00Z"), calendar: la) == date("2026-11-01T08:30:00Z"), "DST repeated hour first occurrence")
        check(task.nextOccurrence(after: date("2026-11-01T08:30:00Z"), calendar: la) == date("2026-11-02T09:30:00Z"), "DST repeated hour never fires twice")
        task.hour = 8; task.minute = 0
        var shanghai = utc; shanghai.timeZone = TimeZone(identifier: "Asia/Shanghai")!
        check(task.nextOccurrence(after: date("2026-10-07T00:00:00Z"), calendar: shanghai) == date("2026-10-08T00:00:00Z"), "local time zone wall clock")
        task.name = "  中文任务  "
        check(task.displayName == "中文任务", "trim custom name")
        task.name = " \n"
        check(task.displayName == task.prompt, "name falls back to Chinese prompt")

        // Claim/recovery use the same pure state transition as the production store.
        let now = Date()
        task.nextRunAt = now.addingTimeInterval(-3 * 86400)
        var snapshot = ScheduledTaskSnapshot(tasks: [task])
        let claimed = snapshot.claim(taskID: task.id, at: now)
        check(claimed != nil && snapshot.runs.count == 1, "claim missed repetitions once")
        check(snapshot.tasks[0].nextRunAt! > now, "coalesce missed days into next future occurrence")
        check(snapshot.claim(taskID: task.id, at: now) == nil, "duplicate claim rejected")
        snapshot.recoverInterruptedRuns(at: now)
        check(snapshot.runs[0].status == .interrupted && snapshot.runs[0].finishedAt == now, "crash recovery marks interrupted")
        check(snapshot.claim(taskID: task.id, at: now) == nil, "crash recovery does not replay charged prompt")
        task.repeatRule = .once; task.nextRunAt = now.addingTimeInterval(-60)
        snapshot = ScheduledTaskSnapshot(tasks: [task])
        check(snapshot.claim(taskID: task.id, at: now) != nil && !snapshot.tasks[0].isEnabled && snapshot.tasks[0].nextRunAt == nil, "one-shot disabled atomically")
        task.isEnabled = false
        snapshot = ScheduledTaskSnapshot(tasks: [task])
        check(snapshot.claim(taskID: task.id, at: now) == nil, "paused task not claimed")
        task.isEnabled = true; task.endDate = now.addingTimeInterval(-86400 * 2)
        snapshot = ScheduledTaskSnapshot(tasks: [task])
        check(snapshot.claim(taskID: task.id, at: now) == nil, "expired task never caught up")
        task.endDate = nil; task.nextRunAt = now.addingTimeInterval(3600)
        snapshot = ScheduledTaskSnapshot(tasks: [task])
        check(snapshot.claim(taskID: task.id, at: now) == nil, "future task not claimed early")

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ze-scheduler-tests-\(UUID())")
        defer { try? FileManager.default.removeItem(at: temp) }
        let repository = ScheduledTaskRepository(fileURL: temp.appendingPathComponent("state.json"))
        let empty = try repository.load()
        check(empty.tasks.isEmpty && empty.runs.isEmpty, "missing storage starts empty")
        try repository.write(snapshot)
        let loaded = try repository.load()
        check(loaded.tasks == snapshot.tasks, "JSON roundtrip preserves Chinese configuration")
        let run = ScheduledTaskRun(taskId: task.id, taskName: task.displayName, scheduledAt: now, startedAt: now)
        snapshot.runs = [run]
        try repository.write(snapshot)
        var recovered = try repository.load(); recovered.recoverInterruptedRuns(at: now)
        try repository.write(recovered)
        let afterRecovery = try repository.load()
        check(afterRecovery.runs[0].status == .interrupted, "recovered status persists after restart")
        let corrupt = Data("{broken-data".utf8)
        try corrupt.write(to: repository.fileURL)
        do { _ = try repository.load(); fatalError("corrupt storage accepted") } catch { count += 1; print("PASS: corrupt JSON rejected") }
        let kept = try Data(contentsOf: repository.fileURL)
        check(kept == corrupt, "corrupt original preserved for recovery")
        snapshot.version = 2; try repository.write(snapshot)
        do { _ = try repository.load(); fatalError("future version accepted") } catch { count += 1; print("PASS: unknown data version rejected") }
        var latch = ScheduledTaskCompletionLatch()
        check(latch.result == nil, "new turn receipt has no result")
        check(latch.finish(ScheduledTaskTurnResult(status: .interrupted, summary: "original", error: "stopped")), "first turn completion wins")
        check(!latch.finish(ScheduledTaskTurnResult(status: .succeeded, summary: "later user turn", error: nil)), "later completion cannot overwrite cancellation")
        check(latch.result?.status == .interrupted && latch.result?.summary == "original", "result remains bound to original turn")
        var successLatch = ScheduledTaskCompletionLatch()
        successLatch.finish(ScheduledTaskTurnResult(status: .succeeded, summary: "scheduled answer", error: nil))
        check(!successLatch.finish(ScheduledTaskTurnResult(status: .interrupted, summary: "", error: "late cancel")), "late cancellation cannot change completed run")
        snapshot.version = 1
        task.isEnabled = true; task.repeatRule = .daily; task.nextRunAt = now.addingTimeInterval(-60)
        snapshot = ScheduledTaskSnapshot(tasks: [task])
        _ = snapshot.claim(taskID: task.id, at: now)
        try repository.write(snapshot)
        var terminal = snapshot
        terminal.runs[0].status = .succeeded
        terminal.runs[0].finishedAt = now
        // Simulate failed terminal persistence: durable claim remains running,
        // but retry writes only the terminal record, never resets nextRunAt.
        let durableClaim = try repository.load()
        check(durableClaim.runs[0].status == .running, "pending terminal write retains original durable claim")
        try repository.write(terminal)
        let flushed = try repository.load()
        check(flushed.runs[0].status == .succeeded && flushed.tasks[0].nextRunAt == snapshot.tasks[0].nextRunAt, "terminal retry preserves claimed next occurrence")
        print("Scheduled task tests passed: \(count)")
    }
}
