import Foundation

@main
enum StorageMaintenanceChecks {
    static func main() throws {
        let manager = FileManager.default
        let home = manager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporary = home.appendingPathComponent("tmp", isDirectory: true)
        let caches = home.appendingPathComponent("Library/Caches", isDirectory: true)
        defer { try? manager.removeItem(at: home) }

        func file(_ path: String) throws -> URL {
            let url = home.appendingPathComponent(path)
            try manager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(repeating: 37, count: 16384).write(to: url)
            return url
        }

        let original = try file("Documents/original")
        let hidden = try file("tmp/.untagged/file")
        let playing = try file("tmp/audio/current/file")
        let cached = try file("Library/Caches/unregistered/file")
        let nested = try file("Library/Caches/nested/InputAttachments/file")
        let draft = try file("Library/Caches/InputAttachments/draft")
        let other = try file("Other/extra")
        let exportStage = try file("tmp/favorites-export/stage/file")
        let exportZIP = try file("tmp/favorites-export/export.zip")
        let exportWorkspace = exportZIP.deletingLastPathComponent()
        try manager.linkItem(at: hidden, to: temporary.appendingPathComponent("hard-link"))
        try manager.linkItem(at: original, to: home.appendingPathComponent("Library/original-link"))
        let alias = temporary.appendingPathComponent("alias")
        try manager.createSymbolicLink(at: alias, withDestinationURL: original.deletingLastPathComponent())

        func allocated(_ file: URL) throws -> Int64 {
            let values = try file.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey])
            guard let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                throw CocoaError(.fileReadUnknown)
            }
            return Int64(bytes)
        }

        let sizes = try [original, hidden, playing, cached, nested, draft, other, exportStage, exportZIP].map(allocated)
        let exportBytes = sizes[7] + sizes[8]
        let occupancy = StorageMaintenance.occupancy(home: home)
        precondition(occupancy.total.failed == 0 && occupancy.total.bytes == sizes.reduce(0, +))
        precondition(occupancy.documents.bytes == sizes[0] && occupancy.library.bytes == sizes[0] + sizes[3] + sizes[4] + sizes[5])
        precondition(occupancy.temporary.bytes == sizes[1] + sizes[2] + exportBytes)

        let lease = StorageMediaFileLease(folder: playing.deletingLastPathComponent())
        var urlCacheClears = 0
        let tempSweep = withExtendedLifetime(lease) {
            let exportLease = StorageMediaFileLease(folder: exportWorkspace)
            return withExtendedLifetime(exportLease) {
                StorageMaintenance.sweep(.temporary, root: temporary) { urlCacheClears += 1 }
            }
        }
        precondition(tempSweep.before?.bytes == sizes[1] + sizes[2] + exportBytes && tempSweep.after?.bytes == sizes[2] + exportBytes)
        precondition(tempSweep.netReduction == sizes[1] && tempSweep.skips.inUse == 2 && tempSweep.skips.failed == 0)
        precondition(!manager.fileExists(atPath: hidden.path) && !manager.fileExists(atPath: alias.path))
        precondition(manager.fileExists(atPath: original.path) && manager.fileExists(atPath: playing.path))
        precondition(manager.fileExists(atPath: exportStage.path) && manager.fileExists(atPath: exportZIP.path))
        let deliveredExportSweep = withExtendedLifetime(lease) {
            StorageMaintenance.sweep(.temporary, root: temporary) { urlCacheClears += 1 }
        }
        precondition(deliveredExportSweep.netReduction == exportBytes && !manager.fileExists(atPath: exportWorkspace.path))

        let cacheSweep = StorageMaintenance.sweep(.caches, root: caches) { urlCacheClears += 1 }
        precondition(cacheSweep.before?.bytes == sizes[3] + sizes[4] && cacheSweep.after?.bytes == 0)
        precondition(cacheSweep.netReduction == sizes[3] + sizes[4] && cacheSweep.skips.excluded == 1 && cacheSweep.skips.failed == 0)
        precondition(StorageMaintenance.draftUsage(root: caches).bytes == sizes[5] && urlCacheClears == 1)
        precondition(manager.fileExists(atPath: draft.path) && !manager.fileExists(atPath: nested.path))

        let complete = StorageUsage(bytes: 4096)
        let larger = StorageUsage(bytes: 8192)
        let partial = StorageUsage(bytes: 4096, failed: 1)
        precondition(StorageMaintenance.Cleanup(before: complete, after: larger).netReduction == -4096)
        precondition(StorageMaintenance.Cleanup(before: complete, after: complete).netReduction == 0)
        precondition(StorageMaintenance.Cleanup(before: partial, after: complete).netReduction == nil)
        precondition(StorageMaintenance.Cleanup(before: complete, after: partial).netReduction == nil)
        precondition(StorageMaintenance.Cleanup(before: complete, after: nil).netReduction == nil)

        print("tmp: \(tempSweep.before!.bytes) -> \(tempSweep.after!.bytes), in use \(tempSweep.skips.inUse), failed \(tempSweep.skips.failed)")
        print("Caches: \(cacheSweep.before!.bytes) -> \(cacheSweep.after!.bytes), excluded \(cacheSweep.skips.excluded), failed \(cacheSweep.skips.failed); drafts \(sizes[5])")
    }
}
