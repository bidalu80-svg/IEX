import Foundation
import Darwin

struct StorageCacheFileResult: Sendable {
    var bytes: Int64 = 0
    var failed = 0
    var inUse = 0

    mutating func merge(_ other: Self) {
        bytes += other.bytes
        failed += other.failed
        inUse += other.inUse
    }
}

enum StorageCacheFiles {
    enum Area: Sendable {
        case favicons, audio, remotePreviews, modelCatalogs, probe

        static let modelDirectories = [
            "com.ze.app.antigravity-models-cache",
            "com.ze.app.gemini-models-cache",
            "com.ze.app.models-cache",
            "com.ze.app.openai-models-cache",
            "com.ze.app.openrouter-models-cache"
        ]

        var locations: [(base: URL?, components: [String])] {
            let fm = FileManager.default
            switch self {
            case .favicons:
                return [(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first, ["ZeChat", "browser_favicons"])]
            case .audio:
                return [(fm.temporaryDirectory, ["simple-audio"])]
            case .remotePreviews:
                return [(fm.urls(for: .cachesDirectory, in: .userDomainMask).first, ["RemoteDiskPreviews"])]
            case .modelCatalogs:
                let caches = fm.urls(for: .cachesDirectory, in: .userDomainMask).first
                return Self.modelDirectories.map { (caches, [$0]) } + [(caches, ["com.ze.app.models-dev-cache"])]
            case .probe:
                return [(fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first, ["AOJIT"])]
            }
        }

        var groupsFiles: Bool { self == .audio || self == .remotePreviews }

        var mediaDirectory: URL? {
            guard groupsFiles, let location = locations.first, let base = location.base else { return nil }
            return base.appendingPathComponent(location.components[0], isDirectory: true)
        }

        func permitsGroup(_ name: String) -> Bool {
            switch self {
            case .audio: return StorageCacheFiles.isHex(name, length: 64)
            case .remotePreviews: return UUID(uuidString: name) != nil
            default: return false
            }
        }

        func permitsFile(_ file: URL, in directory: URL) -> Bool {
            switch self {
            case .audio, .remotePreviews: return true
            case .favicons:
                let name = file.deletingPathExtension().lastPathComponent
                return file.pathExtension == "png"
                    && (name.hasSuffix("-i") || name.hasSuffix("-l"))
                    && StorageCacheFiles.isHex(String(name.dropLast(2)), length: 16)
            case .modelCatalogs:
                if directory.lastPathComponent == "com.ze.app.models-dev-cache" { return file.lastPathComponent == "api.json" }
                return file.pathExtension == "json"
                    && StorageCacheFiles.isHex(file.deletingPathExtension().lastPathComponent, length: 64)
            case .probe: return file.lastPathComponent == "probe.json"
            }
        }
    }

    static func process(_ area: Area, clear: Bool) -> StorageCacheFileResult {
        var result = StorageCacheFileResult()
        for location in area.locations {
            do {
                guard let base = location.base else { result.failed += 1; continue }
                let directory = location.components.reduce(base) { $0.appendingPathComponent($1, isDirectory: true) }
                try withCacheDirectory(base, components: location.components) { descriptor in
                    let entries = try directoryEntries(in: descriptor)
                    if area.groupsFiles {
                        for name in entries where area.permitsGroup(name) {
                            do {
                                guard let groupDescriptor = try openCacheSubdirectory(name, in: descriptor) else { continue }
                                defer { close(groupDescriptor) }
                                let group = directory.appendingPathComponent(name, isDirectory: true)
                                for file in try directoryEntries(in: groupDescriptor) {
                                    visit(file, in: groupDescriptor, base: base, components: location.components + [name],
                                          protectedBy: group, clear: clear, result: &result)
                                }
                            } catch { result.failed += 1 }
                        }
                    } else {
                        for name in entries where area.permitsFile(directory.appendingPathComponent(name), in: directory) {
                            visit(name, in: descriptor, base: base, components: location.components,
                                  protectedBy: nil, clear: clear, result: &result)
                        }
                    }
                }
            } catch { result.failed += 1 }
        }
        return result
    }

    private static func withCacheDirectory(_ base: URL, components: [String], scan: (Int32) throws -> Void) throws {
        var basePath = base.path
        while basePath.count > 1, basePath.last == "/" { basePath.removeLast() }
        var descriptor = basePath.withCString { open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC) }
        guard descriptor >= 0 else {
            let status = errno
            if status == ENOENT { return }
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        defer { close(descriptor) }
        for component in components {
            guard let child = try openCacheSubdirectory(component, in: descriptor) else { return }
            close(descriptor)
            descriptor = child
        }
        try scan(descriptor)
    }

    private static func openCacheSubdirectory(_ name: String, in parent: Int32) throws -> Int32? {
        let descriptor = openat(parent, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else {
            let status = errno
            if status == ENOENT || status == ENOTDIR || status == ELOOP { return nil }
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        return descriptor
    }

    private static func directoryEntries(in descriptor: Int32) throws -> [String] {
        let streamDescriptor = dup(descriptor)
        guard streamDescriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        guard let stream = fdopendir(streamDescriptor) else {
            let status = errno
            close(streamDescriptor)
            throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
        }
        defer { closedir(stream) }
        var names: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                let status = errno
                if status == 0 { return names }
                throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO)
            }
            let length = Int(entry.pointee.d_namlen)
            let name = withUnsafeBytes(of: &entry.pointee.d_name) { bytes in
                String(bytes: bytes.prefix(length), encoding: .utf8)
            }
            if let name, name != ".", name != ".." { names.append(name) }
        }
    }

    private static func visit(_ name: String, in descriptor: Int32, base: URL, components: [String], protectedBy group: URL?,
                              clear: Bool, result: inout StorageCacheFileResult) {
        var info = stat()
        guard fstatat(descriptor, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno != ENOENT { result.failed += 1 }
            return
        }
        guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return }
        result.bytes += Int64(info.st_size)
        guard clear else { return }
        do {
            if let group {
                let removed = try StorageMediaFileLease.withUnusedFolder(group) {
                    try removeFile(name, base: base, components: components)
                }
                if !removed { result.inUse += 1 }
            } else {
                try removeFile(name, base: base, components: components)
            }
        } catch { result.failed += 1 }
    }

    private static func removeFile(_ name: String, base: URL, components: [String]) throws {
        var basePath = base.path
        while basePath.count > 1, basePath.last == "/" { basePath.removeLast() }
        let status = basePath.withCString { path -> Int32 in
            var directory = open(path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard directory >= 0 else { return errno }
            defer { close(directory) }
            for component in components {
                let child = openat(directory, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return errno }
                close(directory)
                directory = child
            }
            var info = stat()
            guard fstatat(directory, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { return errno }
            guard (info.st_mode & mode_t(S_IFMT)) == mode_t(S_IFREG) else { return 0 }
            return unlinkat(directory, name, 0) == 0 ? 0 : errno
        }
        guard status == 0 || status == ENOENT else { throw POSIXError(POSIXErrorCode(rawValue: status) ?? .EIO) }
    }

    private static func isHex(_ text: String, length: Int) -> Bool {
        text.utf8.count == length && text.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}

final class StorageMediaFileLease: @unchecked Sendable {
    let folder: URL
    private static let lock = NSLock()
    private static var counts: [String: Int] = [:]

    private init(folder: URL) {
        self.folder = folder
        Self.lock.lock()
        Self.counts[folder.path, default: 0] += 1
        Self.lock.unlock()
    }

    deinit {
        Self.lock.lock()
        let count = Self.counts[folder.path, default: 1]
        Self.counts[folder.path] = count > 1 ? count - 1 : nil
        Self.lock.unlock()
    }

    static func audio(for file: URL) -> StorageMediaFileLease? {
        let area = StorageCacheFiles.Area.audio
        let folder = file.deletingLastPathComponent()
        guard file.isFileURL, folder.deletingLastPathComponent().path == area.mediaDirectory?.path,
              area.permitsGroup(folder.lastPathComponent) else { return nil }
        return StorageMediaFileLease(folder: folder)
    }

    static func remotePreview() throws -> StorageMediaFileLease {
        guard let root = StorageCacheFiles.Area.remotePreviews.mediaDirectory else { throw CocoaError(.fileNoSuchFile) }
        return StorageMediaFileLease(folder: root.appendingPathComponent(UUID().uuidString, isDirectory: true))
    }

    fileprivate static func withUnusedFolder(_ folder: URL, remove: () throws -> Void) rethrows -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard counts[folder.path] == nil else { return false }
        try remove()
        return true
    }
}
