import Foundation

/// Compiled into both the main app target and the Share Extension target.
enum SharedContainerStore {
    static let appGroupID = "group.com.ze.app"

    static var appGroupContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupID)
    }

    static var hasAppGroupContainer: Bool {
        appGroupContainerURL != nil
    }

    static var persistentContainerURL: URL {
        if let appGroupURL = appGroupContainerURL {
            return appGroupURL
        }

        let library = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
        let fallback = library.appendingPathComponent("ZeChat/AppGroupFallback", isDirectory: true)
        try? FileManager.default.createDirectory(at: fallback, withIntermediateDirectories: true)
        return fallback
    }

    static var sharedFileDirectory: URL? {
        appGroupContainerURL?
            .appendingPathComponent("ShareExtension", isDirectory: true)
    }

    static var shareInbox: PendingShareInbox? {
        guard let container = appGroupContainerURL else { return nil }
        return PendingShareInbox(directory: container.appendingPathComponent("IncomingAttachments", isDirectory: true))
    }
}
