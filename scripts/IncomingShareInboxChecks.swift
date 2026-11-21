import Foundation

@main struct IncomingShareInboxChecks {
    static func main() throws {
        let manager = FileManager.default
        let root = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? manager.removeItem(at: root) }
        let inbox = PendingShareInbox(directory: root.appendingPathComponent("IncomingAttachments", isDirectory: true))
        let firstBytes = Data([0x25, 0x50, 0x44, 0x46])
        let secondBytes = Data([0xff, 0x00])
        let name = "\u{6587}\u{6863}.pdf"
        let first = try inbox.storeFile(named: name) { try firstBytes.write(to: $0) }
        let second = try inbox.storeFile(named: name) { destination in
            precondition(inbox.receipts().map(\.id) == [first.id], "Do not expose a partially written file")
            try secondBytes.write(to: destination)
        }
        let plainText = try inbox.storeText("https://example.invalid/")
        let reopened = PendingShareInbox(directory: inbox.directory)
        let pending = Dictionary(uniqueKeysWithValues: reopened.receipts().map { ($0.id, $0) })
        let firstReceipt = try require(pending[first.id])
        let secondReceipt = try require(pending[second.id])
        let firstFile = try require(firstReceipt.fileURL)
        let secondFile = try require(secondReceipt.fileURL)
        precondition(firstFile != secondFile && firstFile.lastPathComponent == name && secondFile.lastPathComponent == name)
        let firstRead = try Data(contentsOf: firstFile)
        let secondRead = try Data(contentsOf: secondFile)
        precondition(firstRead == firstBytes && secondRead == secondBytes)

        do {
            _ = try inbox.storeFile(named: "failed.pdf") { destination in
                try firstBytes.write(to: destination)
                throw CocoaError(.fileWriteUnknown)
            }
            preconditionFailure("A failed copy must not publish a receipt")
        } catch {}
        let entries = try manager.contentsOfDirectory(atPath: inbox.directory.path)
        precondition(entries.count == 3)
        try firstReceipt.remove()
        precondition(Set(reopened.receipts().map(\.id)) == [second.id, plainText.id])
        precondition(!manager.fileExists(atPath: firstFile.path) && manager.fileExists(atPath: secondFile.path))

        let source = root.appendingPathComponent("large.bin")
        try Data().write(to: source)
        let handle = try FileHandle(forWritingTo: source)
        let largeSize = 64 * 1024 * 1024
        try handle.truncate(atOffset: UInt64(largeSize))
        try handle.close()
        let large = try inbox.storeFile(named: source.lastPathComponent) { destination in
            try PendingShareInbox.copyRegularFile(at: source, to: destination)
        }
        let largeFile = try require(reopened.receipts().first { $0.id == large.id }?.fileURL)
        let size = try largeFile.resourceValues(forKeys: [.fileSizeKey]).fileSize
        precondition(size == largeSize)
        print("PASS: durable receipts, hidden staging, original names and bytes, per-ID cleanup, and direct large-file copy")
    }

    private static func require<Value>(_ value: Value?) throws -> Value {
        guard let value else { throw CocoaError(.fileReadUnknown) }
        return value
    }
}
