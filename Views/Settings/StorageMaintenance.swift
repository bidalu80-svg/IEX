import Foundation
import Darwin
import WebKit

struct StorageUsage: Sendable {
    var bytes: Int64 = 0
    var failed = 0

    mutating func merge(_ other: Self) {
        bytes += other.bytes
        failed += other.failed
    }
}

enum StorageMaintenance {
    private static let inputAttachments = "InputAttachments"
    private static let allocationKeys: Set<URLResourceKey> = [.totalFileAllocatedSizeKey, .fileAllocatedSizeKey]

    private struct FileIdentity: Hashable {
        let device: dev_t
        let inode: ino_t
    }

    private struct AllocationScan {
        var usage = StorageUsage()
        private var linkedFiles: [FileIdentity: Int64] = [:]

        mutating func record(_ bytes: Int64, for info: stat) {
            if info.st_nlink > 1 {
                let identity = FileIdentity(device: info.st_dev, inode: info.st_ino)
                guard linkedFiles[identity] == nil else { return }
                linkedFiles[identity] = bytes
            }
            usage.bytes += bytes
        }

        mutating func merge(_ other: Self) {
            usage.merge(other.usage)
            for (identity, bytes) in other.linkedFiles {
                if linkedFiles[identity] == nil {
                    linkedFiles[identity] = bytes
                } else {
                    usage.bytes -= bytes
                }
            }
        }
    }

    enum Area: String, Sendable {
        case temporary, caches

        var url: URL? {
            switch self {
            case .temporary: return FileManager.default.temporaryDirectory
            case .caches: return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            }
        }

        func excludes(_ name: String) -> Bool {
            self == .caches && name.caseInsensitiveCompare(StorageMaintenance.inputAttachments) == .orderedSame
        }
    }

    struct Occupancy: Sendable {
        var total = StorageUsage()
        var documents = StorageUsage()
        var library = StorageUsage()
        var temporary = StorageUsage()
    }

    struct Skips: Sendable {
        var inUse = 0
        var failed = 0
        var excluded = 0
    }

    struct Cleanup: Sendable {
        let before: StorageUsage?
        let after: StorageUsage?
        var skips = Skips()

        var netReduction: Int64? {
            guard let before, let after, before.failed == 0, after.failed == 0 else { return nil }
            return before.bytes - after.bytes
        }
    }

    static func occupancy(home: URL = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)) -> Occupancy {
        var occupancy = Occupancy()
        var total = AllocationScan()
        do {
            let exists = try withDirectory(home) { descriptor in
                for name in try directoryEntries(in: descriptor) {
                    let info: stat?
                    do { info = try entryStatus(name, in: descriptor) }
                    catch { total.usage.failed += 1; continue }
                    guard let info, isKind(info, S_IFDIR) else { continue }
                    var area = AllocationScan()
                    measureEntry(name, in: descriptor, url: home.appendingPathComponent(name), scan: &area)
                    total.merge(area)
                    switch name {
                    case "Documents": occupancy.documents = area.usage
                    case "Library": occupancy.library = area.usage
                    case "tmp": occupancy.temporary = area.usage
                    default: break
                    }
                }
            }
            if !exists { total.usage.failed += 1 }
        } catch {
            total.usage.failed += 1
        }
        occupancy.total = total.usage
        return occupancy
    }

    static func measure(_ root: URL, selects: (String) -> Bool = { _ in true }) -> StorageUsage? {
        var scan = AllocationScan()
        guard scanDirectory(root, selects: selects, scan: &scan) else { return nil }
        return scan.usage
    }

    fileprivate static func measureLocations(_ paths: [URL], allowMissing: Bool) -> StorageUsage? {
        guard !paths.isEmpty else { return nil }
        var scan = AllocationScan()
        for path in paths {
            let exists = scanDirectory(path, selects: { _ in true }, scan: &scan)
            guard (exists || allowMissing), scan.usage.failed == 0 else { return nil }
        }
        return scan.usage
    }

    private static func scanDirectory(_ root: URL, selects: (String) -> Bool, scan: inout AllocationScan) -> Bool {
        do {
            return try withDirectory(root) { descriptor in
                for name in try directoryEntries(in: descriptor) where selects(name) {
                    measureEntry(name, in: descriptor, url: root.appendingPathComponent(name), scan: &scan)
                }
            }
        } catch {
            scan.usage.failed += 1
            return true
        }
    }

    static func usage(_ area: Area, root: URL? = nil) -> StorageUsage {
        guard let root = root ?? area.url else { return StorageUsage(failed: 1) }
        return measure(root, selects: { !area.excludes($0) }) ?? StorageUsage()
    }

    static func draftUsage(root: URL? = nil) -> StorageUsage {
        guard let root = root ?? Area.caches.url else { return StorageUsage(failed: 1) }
        return measure(root, selects: Area.caches.excludes) ?? StorageUsage()
    }

    static func sweep(_ area: Area, root: URL? = nil, clearURLCache: () -> Void = { URLCache.shared.removeAllCachedResponses() }) -> Cleanup {
        guard let root = root ?? area.url else {
            if area == .caches { clearURLCache() }
            return Cleanup(before: nil, after: nil, skips: Skips(failed: 1))
        }
        let before = usage(area, root: root)
        var skips = Skips()
        do {
            _ = try withDirectory(root) { descriptor in
                for name in try directoryEntries(in: descriptor) {
                    if area.excludes(name) {
                        skips.excluded += 1
                    } else {
                        removeEntry(name, in: descriptor, url: root.appendingPathComponent(name), skips: &skips)
                    }
                }
            }
        } catch { skips.failed += 1 }
        if area == .caches { clearURLCache() }
        let after = usage(area, root: root)
        return Cleanup(before: before, after: after, skips: skips)
    }

    private static func withDirectory(_ root: URL, visit: (Int32) throws -> Void) throws -> Bool {
        var path = root.path
        while path.count > 1, path.last == "/" { path.removeLast() }
        let descriptor = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let status = errno
            if status == ENOENT { return false }
            throw posixError(status)
        }
        defer { close(descriptor) }
        try visit(descriptor)
        return true
    }

    private static func openDirectory(_ name: String, in parent: Int32, matching expected: stat) throws -> Int32? {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let status = errno
            if status == ENOENT { return nil }
            throw posixError(status)
        }
        var current = stat()
        guard fstat(descriptor, &current) == 0, sameEntry(expected, current) else {
            close(descriptor)
            throw POSIXError(.EBUSY)
        }
        return descriptor
    }

    private static func directoryEntries(in descriptor: Int32) throws -> [String] {
        let streamDescriptor = dup(descriptor)
        guard streamDescriptor >= 0 else { throw posixError(errno) }
        guard let stream = fdopendir(streamDescriptor) else {
            let status = errno
            close(streamDescriptor)
            throw posixError(status)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                let status = errno
                if status == 0 { return names }
                throw posixError(status)
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(length), encoding: .utf8)
            }
            guard let name else { throw POSIXError(.EILSEQ) }
            if name != ".", name != ".." { names.append(name) }
        }
    }

    private static func entryStatus(_ name: String, in descriptor: Int32) throws -> stat? {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            let status = errno
            if status == ENOENT { return nil }
            throw posixError(status)
        }
        return info
    }

    private static func isKind(_ info: stat, _ kind: mode_t) -> Bool {
        (info.st_mode & S_IFMT) == kind
    }

    private static func sameEntry(_ first: stat, _ second: stat) -> Bool {
        first.st_dev == second.st_dev && first.st_ino == second.st_ino
    }

    private static func measureEntry(_ name: String, in parent: Int32, url: URL, scan: inout AllocationScan) {
        do {
            guard let info = try entryStatus(name, in: parent) else { return }
            if isKind(info, S_IFDIR) {
                guard let directory = try openDirectory(name, in: parent, matching: info) else { return }
                defer { close(directory) }
                for child in try directoryEntries(in: directory) {
                    measureEntry(child, in: directory, url: url.appendingPathComponent(child), scan: &scan)
                }
                return
            }
            guard isKind(info, S_IFREG) else { return }
            let values = try url.resourceValues(forKeys: allocationKeys)
            guard let current = try entryStatus(name, in: parent), sameEntry(info, current),
                  let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize else {
                scan.usage.failed += 1
                return
            }
            scan.record(Int64(bytes), for: current)
        } catch { scan.usage.failed += 1 }
    }

    private static func removeEntry(_ name: String, in parent: Int32, url: URL, skips: inout Skips) {
        do {
            guard let info = try entryStatus(name, in: parent) else { return }
            guard !StorageMediaFileLease.isInUse(url) else { skips.inUse += 1; return }
            let isDirectory = isKind(info, S_IFDIR)
            if isDirectory {
                guard let directory = try openDirectory(name, in: parent, matching: info) else { return }
                defer { close(directory) }
                let before = skips.inUse + skips.failed
                for child in try directoryEntries(in: directory) {
                    removeEntry(child, in: directory, url: url.appendingPathComponent(child), skips: &skips)
                }
                guard skips.inUse + skips.failed == before else { return }
            }
            let removed = try StorageMediaFileLease.withUnusedItem(url) {
                guard let current = try entryStatus(name, in: parent) else { return }
                guard sameEntry(info, current) else { throw POSIXError(.EBUSY) }
                let flags: Int32 = isDirectory ? AT_REMOVEDIR : 0
                guard unlinkat(parent, name, flags) == 0 else {
                    let status = errno
                    if status != ENOENT { throw posixError(status) }
                    return
                }
            }
            if !removed { skips.inUse += 1 }
        } catch let error as POSIXError where [.EBUSY, .ETXTBSY, .ENOTEMPTY].contains(error.code) {
            skips.inUse += 1
        } catch { skips.failed += 1 }
    }

    private static func posixError(_ status: Int32) -> POSIXError {
        POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
    }
}

@MainActor
enum StorageBrowserCache {
    private static let types: Set<String> = [WKWebsiteDataTypeDiskCache, WKWebsiteDataTypeMemoryCache]

    static func usage() async -> StorageUsage? {
        await measure(locations(for: await identifiers()))
    }

    static func clear() async -> StorageMaintenance.Cleanup {
        let ids = await identifiers()
        let paths = locations(for: ids)
        let before = await measure(paths)
        var stores = [WKWebsiteDataStore.default()]
        if #available(iOS 17.0, macOS 14.0, *) {
            stores += ids.map { WKWebsiteDataStore(forIdentifier: $0) }
        }
        for store in stores {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                store.removeData(ofTypes: types, modifiedSince: .distantPast) { continuation.resume() }
            }
        }
        let after = await measure(paths, allowMissing: before != nil)
        return StorageMaintenance.Cleanup(before: before, after: after)
    }

    private static func identifiers() async -> [UUID] {
        if #available(iOS 17.0, macOS 14.0, *) {
            return await withCheckedContinuation { continuation in
                WKWebsiteDataStore.fetchAllDataStoreIdentifiers { continuation.resume(returning: $0) }
            }
        }
        return []
    }

    private static func locations(for ids: [UUID]) -> [URL] {
        let manager = FileManager.default
        var paths: [URL] = []
        if let caches = StorageMaintenance.Area.caches.url {
            paths.append(caches.appendingPathComponent("WebKit/NetworkCache", isDirectory: true))
        }
        if let library = manager.urls(for: .libraryDirectory, in: .userDomainMask).first {
            paths += ids.map { library.appendingPathComponent("WebKit/WebsiteDataStore/\($0.uuidString.lowercased())/NetworkCache", isDirectory: true) }
        }
        return paths
    }

    private static func measure(_ paths: [URL], allowMissing: Bool = false) async -> StorageUsage? {
        await Task.detached(priority: .utility) {
            StorageMaintenance.measureLocations(paths, allowMissing: allowMissing)
        }.value
    }
}

final class StorageMediaFileLease: @unchecked Sendable {
    let folder: URL
    private let path: String
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    init(folder: URL) {
        self.folder = folder
        path = folder.standardizedFileURL.path
        Self.lock.lock()
        Self.counts[path, default: 0] += 1
        Self.lock.unlock()
    }

    deinit {
        Self.lock.lock()
        let count = Self.counts[path, default: 1]
        Self.counts[path] = count > 1 ? count - 1 : nil
        Self.lock.unlock()
    }

    static func audio(for file: URL) -> StorageMediaFileLease? {
        let folder = file.deletingLastPathComponent()
        let root = StorageMaintenance.Area.temporary.url?.appendingPathComponent("simple-audio", isDirectory: true)
        let name = folder.lastPathComponent
        guard file.isFileURL, folder.deletingLastPathComponent().path == root?.path,
              name.utf8.count == 64, name.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { return nil }
        return StorageMediaFileLease(folder: folder)
    }

    static func remotePreview() throws -> StorageMediaFileLease {
        guard let root = StorageMaintenance.Area.caches.url else { throw CocoaError(.fileNoSuchFile) }
        return StorageMediaFileLease(folder: root.appendingPathComponent("RemoteDiskPreviews/\(UUID().uuidString)", isDirectory: true))
    }

    fileprivate static func isInUse(_ url: URL) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return hasLease(atOrAbove: url)
    }

    fileprivate static func withUnusedItem(_ url: URL, remove: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !hasLease(atOrAbove: url) else { return false }
        try remove()
        return true
    }

    private static func hasLease(atOrAbove url: URL) -> Bool {
        var path = url.standardizedFileURL.path
        while !path.isEmpty {
            if counts[path] != nil { return true }
            let parent = (path as NSString).deletingLastPathComponent
            if path == parent { break }
            path = parent
        }
        return false
    }
}
