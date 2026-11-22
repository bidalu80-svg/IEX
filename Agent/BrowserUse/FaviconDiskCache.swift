import Foundation

/// Stable, process-independent hash used for favicon cache filenames and the
/// fallback-tile palette. Swift's `hashValue` is salted per launch, so it must
/// never be used for anything persisted or expected to stay identical across
/// app restarts.
enum FaviconHash {
    static func value(for text: String) -> UInt64 {
        // FNV-1a (64 bit) — tiny, deterministic, and plenty for filenames.
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return hash
    }
}

/// On-disk favicon store: one small image per domain, keyed by a stable hash,
/// with a hard directory-size/file-count ceiling and LRU eviction.
///
/// An `actor` because every operation touches the file system and must stay
/// off the main thread. Callers only hand it `Data`; image decoding belongs to
/// `FaviconService` (also off-main).
actor FaviconDiskCache {
    enum Source: Int, Sendable, Equatable {
        case faviconICO = 1
        case pageLink = 2

        var fileSuffix: String {
            switch self {
            case .pageLink: return "l"
            case .faviconICO: return "i"
            }
        }
    }

    struct StoredIcon: Sendable {
        let data: Data
        let source: Source
    }

    struct Usage: Sendable {
        let bytes: Int64
        let files: Int
    }

    private let directory: URL
    private let maxBytes: Int64
    private let maxFiles: Int

    init(directory: URL = FaviconDiskCache.defaultDirectory,
         maxBytes: Int64 = 8 * 1024 * 1024,
         maxFiles: Int = 240) {
        self.directory = directory
        self.maxBytes = maxBytes
        self.maxFiles = maxFiles
    }

    /// `Application Support/ZeChat/browser_favicons` — a dedicated cache
    /// directory next to `browser_history.json` and `browser_tabs/`.
    nonisolated static var defaultDirectory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("ZeChat", isDirectory: true)
            .appendingPathComponent("browser_favicons", isDirectory: true)
    }

    // MARK: - Read / write

    /// Returns the best cached image for this domain. A page-declared icon
    /// outranks a `/favicon.ico` copy, so look for the former first.
    func load(domain: String) -> StoredIcon? {
        prepareDirectory()
        let fileManager = FileManager.default
        for source in [Source.pageLink, .faviconICO] {
            let url = fileURL(domain: domain, source: source)
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            // Modification date doubles as the LRU access clock.
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: url.path)
            return StoredIcon(data: data, source: source)
        }
        return nil
    }

    func store(domain: String, source: Source, data: Data) {
        guard !data.isEmpty else { return }
        prepareDirectory()
        let fileManager = FileManager.default
        let linkURL = fileURL(domain: domain, source: .pageLink)
        let icoURL = fileURL(domain: domain, source: .faviconICO)

        if source == .faviconICO,
           fileManager.fileExists(atPath: linkURL.path) {
            // Never downgrade a page-declared icon that is already cached.
            return
        }

        let target = fileURL(domain: domain, source: source)
        do {
            try data.write(to: target, options: .atomic)
            try? fileManager.setAttributes([.modificationDate: Date()], ofItemAtPath: target.path)
            // The declared icon supersedes any root-favicon copy only after
            // the new file is safely written.
            if source == .pageLink {
                try? fileManager.removeItem(at: icoURL)
            }
        } catch {
            NSLog("[BrowserFavicon] Failed to cache icon for %@: %@", domain, error.localizedDescription)
        }
        enforceLimit()
    }

    /// Current cache footprint (used by diagnostics and acceptance checks).
    func usage() -> Usage {
        prepareDirectory()
        let files = cachedFiles()
        return Usage(bytes: files.reduce(Int64(0)) { $0 + $1.bytes }, files: files.count)
    }

    // MARK: - Housekeeping

    private struct CachedFile {
        let url: URL
        let bytes: Int64
        let modified: Date
    }

    private func cachedFiles() -> [CachedFile] {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Array(keys),
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true else { return nil }
            return CachedFile(
                url: url,
                bytes: Int64(values.fileSize ?? 0),
                modified: values.contentModificationDate ?? .distantPast
            )
        }
    }

    /// Hard ceiling enforcement: evict least-recently-touched files until the
    /// directory is back under both the byte and file-count limits.
    private func enforceLimit() {
        var files = cachedFiles()
        var totalBytes = files.reduce(Int64(0)) { $0 + $1.bytes }
        guard totalBytes > maxBytes || files.count > maxFiles else { return }

        // Leave ~10% headroom so a burst of new icons doesn't immediately
        // trigger another sweep on the very next write.
        let targetBytes = maxBytes - maxBytes / 10
        let targetFiles = max(1, maxFiles - maxFiles / 10)
        files.sort { $0.modified < $1.modified }

        var remainingFiles = files.count
        for file in files {
            guard totalBytes > targetBytes || remainingFiles > targetFiles else { break }
            do {
                try FileManager.default.removeItem(at: file.url)
                totalBytes -= file.bytes
                remainingFiles -= 1
            } catch {
                // A failed delete must not spin forever on the same entry.
                NSLog("[BrowserFavicon] Failed to evict %@: %@", file.url.lastPathComponent, error.localizedDescription)
            }
        }
    }

    private func prepareDirectory() {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: directory.path) else { return }
        try? fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var mutableDirectory = directory
        try? mutableDirectory.setResourceValues(values)
    }

    private func fileURL(domain: String, source: Source) -> URL {
        let key = domain.lowercased()
        let name = String(format: "%016llx-%@.png", FaviconHash.value(for: key), source.fileSuffix)
        return directory.appendingPathComponent(name, isDirectory: false)
    }
}
