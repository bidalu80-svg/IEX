import Foundation
import Darwin

private let importLog = AppLogger(category: "Share")

enum ExternalFileImporter {
    private static let deliveries = DeliveryGate()

    static func canIngest(_ url: URL) -> Bool {
        url.isFileURL
    }

    static var inbox: PendingShareInbox {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return PendingShareInbox(directory: support.appendingPathComponent("IncomingAttachments", isDirectory: true))
    }

    @MainActor
    static func ingest(_ url: URL, into coordinator: ShareCoordinator) {
        guard canIngest(url) else { return }
        let access = url.startAccessingSecurityScopedResource()
        let inbox = self.inbox
        let pendingWasEmpty = coordinator.pending.isEmpty
        coordinator.documentImportStarted()
        let copy = Task.detached(priority: .userInitiated) { () throws -> PendingShare? in
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            return try SecurityScopedDocumentAccess.read(from: url) { readableURL in
                try deliveries.publishOnce(source: readableURL) {
                    try inbox.storeFile(named: url.lastPathComponent) { destination in
                        try PendingShareInbox.copyRegularFile(at: readableURL, to: destination)
                    }
                }
            }
        }
        Task { @MainActor in
            var deliveredID: UUID?
            defer {
                coordinator.documentImportFinished()
                if pendingWasEmpty, let deliveredID {
                    coordinator.noteShareNavigation(receiptID: deliveredID)
                }
            }
            do {
                deliveredID = try await copy.value?.id
            } catch {
                importLog.error("[Share] could not stage document (\((error as NSError).code))")
                coordinator.noteDocumentImportFailure()
            }
        }
    }

    private struct Fingerprint: Hashable {
        let device: dev_t
        let inode: ino_t
        let size: off_t
        let createdSecond: Int
        let createdNanosecond: Int
        let modifiedSecond: Int
        let modifiedNanosecond: Int

        init?(_ source: URL) {
            var info = stat()
            guard lstat(source.path, &info) == 0,
                  (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return nil }
            device = info.st_dev
            inode = info.st_ino
            size = info.st_size
            createdSecond = info.st_birthtimespec.tv_sec
            createdNanosecond = info.st_birthtimespec.tv_nsec
            modifiedSecond = info.st_mtimespec.tv_sec
            modifiedNanosecond = info.st_mtimespec.tv_nsec
        }
    }

    private final class DeliveryGate: @unchecked Sendable {
        private let lock = NSLock()
        private let replayWindow: TimeInterval = 5
        private var copying = Set<Fingerprint>()
        private var committedUntil: [Fingerprint: TimeInterval] = [:]

        func publishOnce(source: URL, publish: () throws -> PendingShare) rethrows -> PendingShare? {
            guard let fingerprint = Fingerprint(source) else { return try publish() }
            let reserved = lock.withLock {
                let now = ProcessInfo.processInfo.systemUptime
                committedUntil = committedUntil.filter { $0.value > now }
                return committedUntil[fingerprint] == nil && copying.insert(fingerprint).inserted
            }
            guard reserved else { return nil }
            var committed = false
            defer {
                lock.withLock {
                    copying.remove(fingerprint)
                    if committed {
                        committedUntil[fingerprint] = ProcessInfo.processInfo.systemUptime + replayWindow
                    }
                }
            }
            let receipt = try publish()
            committed = true
            return receipt
        }
    }
}
