import Foundation

private let importLog = AppLogger(category: "Share")

enum ExternalFileImporter {
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
        coordinator.documentImportStarted()
        let copy = Task.detached(priority: .userInitiated) {
            defer { if access { url.stopAccessingSecurityScopedResource() } }
            try inbox.storeFile(named: url.lastPathComponent) { destination in
                try SecurityScopedDocumentAccess.read(from: url) { readableURL in
                    try PendingShareInbox.copyRegularFile(at: readableURL, to: destination)
                }
            }
        }
        Task { @MainActor in
            defer { coordinator.documentImportFinished() }
            do {
                _ = try await copy.value
            } catch {
                importLog.error("[Share] could not stage document (\((error as NSError).code))")
                coordinator.noteDocumentImportFailure()
            }
        }
    }
}
