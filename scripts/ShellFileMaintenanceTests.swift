import Foundation
import SQLite3

@main struct ShellFileMaintenanceTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ label: String) {
        precondition(value, label)
        checks += 1
        print("PASS \(label)")
    }
    static func exec(_ db: OpaquePointer, _ sql: String) {
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK, String(cString: sqlite3_errmsg(db)))
    }
    static func scalar(_ db: OpaquePointer, _ sql: String) -> Int {
        var statement: OpaquePointer?
        precondition(sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        precondition(sqlite3_step(statement) == SQLITE_ROW)
        return Int(sqlite3_column_int64(statement, 0))
    }
    @MainActor static func main() async throws {
        let fm = FileManager.default
        let work = fm.temporaryDirectory.appendingPathComponent("shell-files-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: work) }
        let meta = work.appendingPathComponent("meta.db", isDirectory: false)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: meta)
        let bucket = work.appendingPathComponent("session-a", isDirectory: true)
        let other = work.appendingPathComponent("session-b", isDirectory: true)
        try fm.createDirectory(at: bucket, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        try Data("other session".utf8).write(to: other.appendingPathComponent("private.txt"))
        let context = ShellFileMaintenance(roots: [.init(linux: "/var/ze/workspace", host: bucket)], metadataURL: meta)
        let empty = await context.snapshot()
        check(empty.isEmpty, "empty current session excludes other session")
        let base = bucket.appendingPathComponent("nested/中文", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        for index in 0..<1_500 {
            try Data("fixture".utf8).write(to: base.appendingPathComponent("file-\(index).txt"))
        }
        try Data().write(to: bucket.appendingPathComponent(".hidden"))
        let first = await context.scanAndRegisterChanges(since: empty)
        check(first.metadataError == nil, "batch metadata registration succeeds")
        check(first.paths.count == 1_500, "all 1500 regular files reported, hidden entries excluded")
        check(first.paths == first.paths.sorted(), "tool output remains deterministic")
        check(first.paths.contains("/var/ze/workspace/nested/中文/file-1499.txt"), "Unicode guest path preserved")
        var handle: OpaquePointer?
        precondition(sqlite3_open(meta.path, &handle) == SQLITE_OK)
        guard let db = handle else { fatalError("database") }
        defer { sqlite3_close(db) }
        let count = scalar(db, "SELECT COUNT(*) FROM paths")
        check(count == 1_505, "shared ancestors registered once: 1500 files + 5 dirs")
        check(scalar(db, "SELECT COUNT(*) FROM stats") == count, "no orphan metadata rows")
        check(scalar(db, "SELECT COUNT(*) FROM paths JOIN stats USING(inode) WHERE hex(stat) = 'ED410000000000000000000000000000'") == 5, "directories retain 0755 mode")
        check(scalar(db, "SELECT COUNT(*) FROM paths JOIN stats USING(inode) WHERE hex(stat) = 'A4810000000000000000000000000000'") == 1_500, "files retain 0644 mode")
        exec(db, "UPDATE stats SET stat = X'ED810000010000000200000000000000' WHERE inode = (SELECT inode FROM paths WHERE path = CAST('/var/ze/workspace/nested/中文/file-0.txt' AS BLOB))")
        let repeatResult = await context.scanAndRegisterChanges(since: [:])
        check(repeatResult.metadataError == nil, "repeat registration succeeds")
        check(scalar(db, "SELECT COUNT(*) FROM paths") == count && scalar(db, "SELECT COUNT(*) FROM stats") == count, "registration is idempotent")
        check(scalar(db, "SELECT COUNT(*) FROM stats WHERE hex(stat) = 'ED810000010000000200000000000000'") == 1, "existing executable permissions and owners retained")
        let before = await context.snapshot()
        let noChanges = await context.scanAndRegisterChanges(since: before)
        check(noChanges.paths.isEmpty, "unchanged files omitted")
        let changed = base.appendingPathComponent("file-0.txt")
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(3)], ofItemAtPath: changed.path)
        let afterEdit = await context.scanAndRegisterChanges(since: before)
        check(afterEdit.paths == ["/var/ze/workspace/nested/中文/file-0.txt"], "only modified path reported")

        // Hold SQLite's real write lock: the worker must wait without blocking
        // MainActor, which continues ticking while the background I/O is pending.
        exec(db, "BEGIN IMMEDIATE")
        var finished = false
        let pending = Task { @MainActor in
            let result = await context.scanAndRegisterChanges(since: [:])
            finished = true
            return result
        }
        var ticks = 0
        for _ in 0..<15 {
            try await Task.sleep(nanoseconds: 20_000_000)
            ticks += 1
        }
        check(!finished && ticks == 15, "MainActor responsive during real SQLite lock contention")
        exec(db, "ROLLBACK")
        let unlocked = await pending.value
        check(unlocked.metadataError == nil, "registration resumes after lock release")

        let rollbackMeta = work.appendingPathComponent("rollback.db", isDirectory: false)
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[1]), to: rollbackMeta)
        var rollbackHandle: OpaquePointer?
        precondition(sqlite3_open(rollbackMeta.path, &rollbackHandle) == SQLITE_OK)
        guard let rollbackDB = rollbackHandle else { fatalError("rollback database") }
        defer { sqlite3_close(rollbackDB) }
        exec(rollbackDB, "CREATE TRIGGER reject_path BEFORE INSERT ON paths BEGIN SELECT RAISE(ABORT, 'fixture rejects path'); END")
        let rejecting = ShellFileMaintenance(roots: [.init(linux: "/var/ze/workspace", host: bucket)], metadataURL: rollbackMeta)
        let rejected = await rejecting.scanAndRegisterChanges(since: [:])
        check(rejected.metadataError != nil, "database failures surfaced")
        check(rejected.paths.count == 1_500, "metadata failure preserves generated file report")
        check(scalar(rollbackDB, "SELECT COUNT(*) FROM stats") == 0 && scalar(rollbackDB, "SELECT COUNT(*) FROM paths") == 0, "failed insertion rolls back both path and stat")
        let missing = ShellFileMaintenance(roots: [.init(linux: "/var/ze/workspace", host: bucket)], metadataURL: work.appendingPathComponent("absent.db"))
        let unavailable = await missing.scanAndRegisterChanges(since: [:])
        check(unavailable.metadataError != nil && !fm.fileExists(atPath: missing.metadataURL.path), "missing metadata is reported without creating a broken db")
        print("PASS shell file maintenance: \(checks) checks")
    }
}
