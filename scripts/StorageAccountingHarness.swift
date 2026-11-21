import Foundation

@main
enum StorageAccountingHarness {
    static func main() throws {
        let fm = FileManager.default
        let fixture = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let home = fixture.appendingPathComponent("home", isDirectory: true)
        let external = fixture.appendingPathComponent("external", isDirectory: true)
        defer { try? fm.removeItem(at: fixture) }

        let sizes = [
            "Documents/alpine-rootfs/data/usr/bin/program": 7,
            "Documents/alpine-rootfs/data/root/.hidden": 11,
            "Documents/alpine-rootfs/meta.db": 13,
            "Documents/report.pdf": 17,
            "Library/Application Support/Ze/Backups/backup.zebak": 19,
            "Library/Caches/InputAttachments/input.pdf": 23,
            "Library/ZeChat/ze.db": 29,
            "Library/ZeChat/ze.db-wal": 31,
            "Library/ZeChat/ze.db-shm": 37,
            "Library/ZeChat/ze.db-journal": 41,
            "Library/ZeChat/ze/session/images/image.png": 43,
            "Library/ZeChat/ze/orphan/file": 47,
            "Library/WebKit/WebsiteData/blob": 53,
            "tmp/stage/archive": 59,
            ".unexpected/data": 61
        ]
        for (path, size) in sizes {
            let file = home.appendingPathComponent(path)
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 23, count: size).write(to: file)
        }
        try fm.createDirectory(at: external, withIntermediateDirectories: true)
        try Data(repeating: 42, count: 71).write(to: external.appendingPathComponent("ignored"))
        try fm.createSymbolicLink(at: home.appendingPathComponent("Documents/alpine-rootfs/link"), withDestinationURL: external)
        try fm.createSymbolicLink(at: home.appendingPathComponent("link"), withDestinationURL: external.appendingPathComponent("ignored"))

        let snapshot = try StorageAccounting.scan(home: home, sessionIDs: ["session", "missing"])
        precondition(snapshot.regions.map(\.name) == ["Documents", "Library/Application Support", "Library/Caches", "Library（其余）", "tmp", ".unexpected"])
        precondition(snapshot.regions.map(\.usage.bytes) == [48, 19, 23, 281, 59, 61])
        precondition(snapshot.total.bytes == 491 && !snapshot.total.isIncomplete)
        precondition(snapshot.regions[0].child(named: "alpine-rootfs")?.child(named: "data")?.child(named: "usr")?.usage.bytes == 7)
        precondition(snapshot.regions[3].child(named: "ZeChat")?.child(named: "ze")?.child(named: "orphan")?.usage.bytes == 47)
        precondition(snapshot.shell.bytes == 31 && snapshot.database.bytes == 138)
        precondition(snapshot.sessions["session"]?.bytes == 43 && snapshot.sessions["missing"]?.bytes == 0)
        precondition(snapshot.sessions["orphan"] == nil)

        let missing = try StorageAccounting.scan(home: fixture.appendingPathComponent("missing"), sessionIDs: ["session"])
        precondition(missing.total.isIncomplete && missing.shell.isIncomplete && missing.database.isIncomplete)
        precondition(missing.sessions["session"]?.isIncomplete == true)
        print("PASS: Swift filesystem fixture")
    }
}
