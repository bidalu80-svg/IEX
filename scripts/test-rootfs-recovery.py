#!/usr/bin/env python3
"""Compile the real RootfsManager and ZIP reader against temporary-root fixtures on macOS.
Only Documents/Bundle lookups and app logger/kernel boundaries are fixture substitutions.
--prepare-only produces source + hashes on Windows without claiming Swift execution.
"""
from pathlib import Path
import hashlib, json, os, re, sqlite3, subprocess, sys, tempfile, zipfile

root = Path(__file__).resolve().parents[1]
out = Path(os.environ.get('RUNNER_TEMP', tempfile.gettempdir())) / 'ze-rootfs-tests'
out.mkdir(parents=True, exist_ok=True)
source = (root / 'iSH/RootfsManager.swift').read_text(encoding='utf-8')
original_hash = hashlib.sha256(source.encode()).hexdigest()
documents = 'FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]'
archive = 'Bundle.main.url(forResource: "alpine-rootfs", withExtension: "zip")'
assert source.count(documents) == 1 and source.count(archive) == 1
source = source.replace(documents, 'RootfsFixture.documents').replace(archive, 'RootfsFixture.archive')
(out / 'RootfsManager.swift').write_text(source, encoding='utf-8')
database = out / 'fixture-meta.db'
if database.exists(): database.unlink()
# Use the schema shipped by the actual fakefsify producer, including meta,
# indexes, version and WAL mode. A toy DELETE-mode database missed the real
# archive's WAL bootstrap during readonly installation validation.
producer = (root / 'Vendor/ZeNative/ish/tools/fakefs.c').read_text(encoding='utf-8')
schema = producer.split('static const char *schema = Q(', 1)[1].split('\n);', 1)[0]
schema = re.sub(r'//[^\n]*', '', schema)
db = sqlite3.connect(database)
db.execute('PRAGMA journal_mode=WAL')
db.executescript(schema)
db.close()
assert database.read_bytes()[18:20] == b'\x02\x02'
with zipfile.ZipFile(out / 'valid.zip', 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('alpine-rootfs/data/', '')
    z.writestr('alpine-rootfs/data/root/', '')
    z.writestr('alpine-rootfs/data/root/bundled.txt', 'fresh')
    z.write(database, 'alpine-rootfs/meta.db')
(out / 'short.zip').write_bytes(b'bad')
with zipfile.ZipFile(out / 'bad-metadata.zip', 'w') as z:
    z.writestr('alpine-rootfs/data/', '')
    z.writestr('alpine-rootfs/meta.db', 'not sqlite')
wrong_schema = out / 'wrong-schema.db'
if wrong_schema.exists(): wrong_schema.unlink()
wrong_db = sqlite3.connect(wrong_schema)
wrong_db.execute('CREATE TABLE unrelated(value TEXT)')
wrong_db.close()
with zipfile.ZipFile(out / 'wrong-schema.zip', 'w', compression=zipfile.ZIP_DEFLATED) as z:
    z.writestr('alpine-rootfs/data/', '')
    z.write(wrong_schema, 'alpine-rootfs/meta.db')
with zipfile.ZipFile(out / 'traversal.zip', 'w') as z:
    z.writestr('alpine-rootfs/../escaped.txt', 'escape')

harness = r'''
import Foundation
import CoreFoundation
import Darwin
import SQLite3

struct AppLogger {
    init(category: String) {}
    func info(_ text: String) { print(text) }
    func warning(_ text: String) { print(text) }
    func error(_ text: String) { print(text) }
}
final class ISHKernel { static let shared = ISHKernel(); var isBooted = false }
enum RootfsFixture {
    static let fixtures = URL(fileURLWithPath: CommandLine.arguments[1])
    static let documents = CommandLine.arguments.count > 2 && CommandLine.arguments[2] != "--archive"
        ? URL(fileURLWithPath: CommandLine.arguments[2]) : fixtures.appendingPathComponent("runtime-" + UUID().uuidString)
    static var archive: URL? = fixtures.appendingPathComponent("valid.zip")
}
@main struct RootfsRecoveryTests {
    static let fm = FileManager.default
    static func read(_ path: URL) throws -> String { try String(contentsOf: path, encoding: .utf8) }
    static func write(_ text: String, _ path: URL) throws {
        try fm.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        try text.write(to: path, atomically: true, encoding: .utf8)
    }
    static func metadata(_ url: URL, _ sql: String) {
        var db: OpaquePointer?
        precondition(sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK)
    }
    static func checkLinkMode(_ manager: RootfsManager) {
        var db: OpaquePointer?, stmt: OpaquePointer?
        precondition(sqlite3_open_v2(manager.rootfsPath.appendingPathComponent("meta.db").path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        precondition(sqlite3_prepare_v2(db, "SELECT hex(stat) FROM paths JOIN stats USING(inode) WHERE path = CAST('/root/link' AS BLOB)", -1, &stmt, nil) == SQLITE_OK)
        defer { sqlite3_finalize(stmt) }
        precondition(sqlite3_step(stmt) == SQLITE_ROW)
        precondition(String(cString: sqlite3_column_text(stmt, 0)) == "FFA10000000000000000000000000000")
    }
    static func check(_ value: Bool) { precondition(value) }
    static func fail(_ body: () throws -> Void) {
        do { try body(); fatalError("Expected failure") } catch { print("Expected error: \(error)") }
    }
    static func main() throws {
        if CommandLine.arguments.count > 2 && CommandLine.arguments[2] == "--archive" {
            let supplied = URL(fileURLWithPath: CommandLine.arguments[3])
            RootfsFixture.archive = supplied
            let manager = RootfsManager.shared
            try fm.createDirectory(at: RootfsFixture.documents, withIntermediateDirectories: true)
            defer { try? fm.removeItem(at: RootfsFixture.documents) }
            try manager.installIfNeeded()
            precondition(manager.isInstalled)
            precondition(fm.fileExists(atPath: manager.dataPath.appendingPathComponent("bin/busybox").path))
            precondition(fm.fileExists(atPath: manager.dataPath.appendingPathComponent("bin/sh").path))
            print("PASS: complete production ZIP reader and installation validate actual bundled Alpine archive")
            return
        }
        if CommandLine.arguments.count > 2 {
            // A genuinely new process: no inherited singleton/boot-state or view-model backup URL.
            let manager = RootfsManager.shared
            precondition(manager.hasPendingUserDataRestore)
            try manager.installIfNeeded()
            precondition(!manager.hasPendingUserDataRestore && manager.isInstalled)
            check(try read(manager.dataPath.appendingPathComponent("root/user.txt")) == "reset-user")
            checkLinkMode(manager)
            return
        }
        let documents = RootfsFixture.documents
        try fm.createDirectory(at: documents, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: documents) }
        let manager = RootfsManager.shared
        let active = manager.rootfsPath
        try manager.installIfNeeded()
        precondition(manager.isInstalled)
        let user = active.appendingPathComponent("data/root/user.txt")
        try write("user-data", user)
        try manager.installIfNeeded()
        check(try read(user) == "user-data")
        print("PASS: real ZIP/SQLite installation and healthy reinstall no-op")

        try write("wrong-arch", active.appendingPathComponent(".arch"))
        for name in ["short.zip", "bad-metadata.zip", "wrong-schema.zip", "traversal.zip"] {
            RootfsFixture.archive = RootfsFixture.fixtures.appendingPathComponent(name)
            fail { try manager.installIfNeeded() }
            check(try read(user) == "user-data")
        }
        precondition(!fm.fileExists(atPath: documents.appendingPathComponent("escaped.txt").path))
        RootfsFixture.archive = nil
        fail { try manager.installIfNeeded() }
        check(try read(user) == "user-data")
        print("PASS: corrupt/short/traversal/missing archives preserve original data")

        RootfsFixture.archive = RootfsFixture.fixtures.appendingPathComponent("valid.zip")
        try manager.installIfNeeded()
        precondition(manager.isInstalled && !fm.fileExists(atPath: user.path))
        let preserved = try fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".alpine-rootfs-recovery-") }
        precondition(preserved.count == 1)
        check(try read(preserved[0].appendingPathComponent("data/root/user.txt")) == "user-data")
        print("PASS: architecture recovery preserves whole original tree under unique sibling")

        // The actual rename implementation must not enumerate deep descendants.
        let deep = documents.appendingPathComponent("deep")
        try fm.createDirectory(at: deep, withIntermediateDirectories: true)
        let cwd = fm.currentDirectoryPath
        precondition(fm.changeCurrentDirectoryPath(deep.path))
        for _ in 0..<20 {
            let component = String(repeating: "d", count: 70)
            precondition(mkdir(component, 0o700) == 0)
            precondition(chdir(component) == 0)
        }
        let fd = open("sentinel", O_WRONLY | O_CREAT, 0o600)
        precondition(fd >= 0)
        precondition("deep-data".withCString { Darwin.write(fd, $0, 9) } == 9)
        close(fd)
        precondition(fm.changeCurrentDirectoryPath(cwd))
        let deepBackup = try RootfsRecovery.preserve(at: deep)!
        precondition(!RootfsRecovery.exists(deep) && RootfsRecovery.exists(deepBackup))
        precondition(fm.changeCurrentDirectoryPath(deepBackup.path))
        for _ in 0..<20 { precondition(chdir(String(repeating: "d", count: 70)) == 0) }
        let readFD = open("sentinel", O_RDONLY)
        precondition(readFD >= 0)
        var bytes = [UInt8](repeating: 0, count: 9)
        precondition(Darwin.read(readFD, &bytes, 9) == 9)
        close(readFD)
        precondition(String(bytes: bytes, encoding: .utf8) == "deep-data")
        precondition(unlink("sentinel") == 0)
        for _ in 0..<20 {
            precondition(chdir("..") == 0)
            precondition(rmdir(String(repeating: "d", count: 70)) == 0)
        }
        precondition(fm.changeCurrentDirectoryPath(cwd))
        print("PASS: deep tree beyond absolute PATH_MAX retires intact without recursive delete")

        let rollback = documents.appendingPathComponent("rollback")
        try write("original", rollback.appendingPathComponent("sentinel"))
        var moves = 0
        fail {
            try RootfsRecovery.replace(at: rollback, move: { src, dst in
                moves += 1
                if moves == 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
                try RootfsRecovery.moveEntry(src, dst)
            }) { stage in try write("replacement", stage.appendingPathComponent("sentinel")) }
        }
        check(moves == 3); check(try read(rollback.appendingPathComponent("sentinel")) == "original")
        print("PASS: failed activation rolls original tree back")
        fail {
            try RootfsRecovery.replace(at: rollback, move: { _, _ in throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }) { stage in
                try write("replacement", stage.appendingPathComponent("sentinel"))
            }
        }
        check(try read(rollback.appendingPathComponent("sentinel")) == "original")
        print("PASS: failed preserve never overwrites original")

        moves = 0
        fail {
            try RootfsRecovery.replace(at: rollback, move: { src, dst in
                moves += 1
                if moves >= 2 { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES)) }
                try RootfsRecovery.moveEntry(src, dst)
            }) { stage in try write("replacement", stage.appendingPathComponent("sentinel")) }
        }
        let rollbackBackups = try fm.contentsOfDirectory(at: documents, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix(".rollback-recovery-") }
        precondition(rollbackBackups.count == 1 && !RootfsRecovery.exists(rollback))
        check(try read(rollbackBackups[0].appendingPathComponent("sentinel")) == "original")
        print("PASS: rollback failure retains original at the reported recovery path")

        try write("reset-user", user)
        try write("user.txt", active.appendingPathComponent("data/root/link"))
        metadata(active.appendingPathComponent("meta.db"), "INSERT INTO stats(stat) VALUES (X'FFA10000000000000000000000000000'); INSERT INTO paths(path,inode) VALUES (CAST('/root/link' AS BLOB),last_insert_rowid());")
        ISHKernel.shared.isBooted = true
        let backup = try manager.reset(keepUserData: true)!
        precondition(manager.didResetWhileBooted && !RootfsRecovery.exists(active))
        check(try read(backup.appendingPathComponent("user.txt")) == "reset-user")
        fail { try manager.installIfNeeded() }
        precondition(manager.hasPendingUserDataRestore)
        // Prove a failed restore retains the journal for retry, even after fresh install completes.
        ISHKernel.shared.isBooted = false
        let held = backup.deletingLastPathComponent().appendingPathComponent("held-root")
        try RootfsRecovery.moveEntry(backup, held)
        fail { try manager.installIfNeeded() }
        precondition(manager.hasPendingUserDataRestore && manager.isInstalled)
        try RootfsRecovery.moveEntry(held, backup)
        // Registration error must roll back and keep the journal instead of silently reporting success.
        metadata(active.appendingPathComponent("meta.db"), "CREATE TRIGGER fixture_fail BEFORE INSERT ON stats BEGIN SELECT RAISE(ABORT, 'fixture metadata failure'); END;")
        fail { try manager.installIfNeeded() }
        precondition(manager.hasPendingUserDataRestore)
        metadata(active.appendingPathComponent("meta.db"), "DROP TRIGGER fixture_fail;")
        let restarted = Process()
        restarted.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        restarted.arguments = [RootfsFixture.fixtures.path, documents.path]
        try restarted.run(); restarted.waitUntilExit()
        precondition(restarted.terminationStatus == 0)
        check(try read(user) == "reset-user")
        check(try read(backup.appendingPathComponent("user.txt")) == "reset-user")
        precondition(!manager.hasPendingUserDataRestore)
        print("PASS: actual process restart auto-restores pending backup, retries failure and clears journal only after success")

        let pendingBackup = try manager.reset(keepUserData: true)!
        let previousTree = pendingBackup.deletingLastPathComponent().deletingLastPathComponent()
        // Simulate exit after journal publication, before its intended rename occurred.
        try RootfsRecovery.moveEntry(previousTree, active)
        let interrupted = Process()
        interrupted.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        interrupted.arguments = [RootfsFixture.fixtures.path, documents.path]
        try interrupted.run(); interrupted.waitUntilExit()
        precondition(interrupted.terminationStatus == 0 && !manager.hasPendingUserDataRestore)
        check(try read(user) == "reset-user")
        print("PASS: write-ahead reset journal survives interruption before rename")
        print("Rootfs production recovery runtime fixtures passed")
    }
}
'''
(out / 'Tests.swift').write_text(harness, encoding='utf-8')
(out / 'manifest.json').write_text(json.dumps({'production_sha256': original_hash,
    'schema_producer_sha256': hashlib.sha256(producer.encode()).hexdigest(),
    'fixture_journal_mode': 'wal',
    'substitutions': ['Documents directory URL', 'Bundle archive URL', 'AppLogger and ISHKernel fixture boundaries']}, indent=2)+'\n')
print('Prepared production RootfsManager fixture:', out)
if '--prepare-only' not in sys.argv:
    subprocess.run(['xcrun','swiftc','-swift-version','5','-parse-as-library',str(out/'RootfsManager.swift'),str(out/'Tests.swift'),'-o',str(out/'test-rootfs')], check=True)
    subprocess.run([str(out/'test-rootfs'),str(out)], check=True)
    if actual_archive := os.environ.get('ZE_ROOTFS_VERIFY_ARCHIVE'):
        archive_path = Path(actual_archive).resolve(strict=True)
        print('Actual archive SHA256:', hashlib.sha256(archive_path.read_bytes()).hexdigest())
        subprocess.run([str(out/'test-rootfs'),str(out),'--archive',str(archive_path)], check=True)
