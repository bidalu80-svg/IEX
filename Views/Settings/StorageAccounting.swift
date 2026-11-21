import Foundation

enum StorageAccounting {
    struct Usage: Sendable {
        var bytes: Int64 = 0
        var isIncomplete = false

        static let unknown = Self(isIncomplete: true)

        static func sum(_ values: [Self]) -> Self {
            values.reduce(into: Self()) { total, value in
                total.bytes += value.bytes
                total.isIncomplete = total.isIncomplete || value.isIncomplete
            }
        }
    }

    struct Entry: Identifiable, Sendable {
        let id: String
        let name: String
        let usage: Usage
        let children: [Self]?

        func child(named name: String) -> Self? {
            children?.first { $0.name == name }
        }

        var missingChildUsage: Usage {
            children == nil && usage.isIncomplete ? .unknown : Usage()
        }

        static func directory(id: String, name: String, children: [Self]) -> Self {
            let sorted = children.sorted {
                if $0.usage.bytes != $1.usage.bytes { return $0.usage.bytes > $1.usage.bytes }
                return $0.name < $1.name
            }
            return Self(id: id, name: name, usage: .sum(sorted.map(\.usage)), children: sorted)
        }
    }

    struct Snapshot: Sendable {
        let regions: [Entry]
        let shell: Usage
        let database: Usage
        let sessions: [String: Usage]
        let total: Usage
    }

    private static let primaryRegions = ["Documents", "Library", "tmp"]
    private static let separateLibraryRegions = ["Application Support", "Caches"]
    private static let databaseFiles = ["ze.db", "ze.db-wal", "ze.db-shm", "ze.db-journal"]
    private static let prefetchKeys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .totalFileSizeKey, .fileSizeKey]
    private static let keys = Set(prefetchKeys)

    static func scan(home: URL, sessionIDs: [String]) throws -> Snapshot {
        let root = try measure(home, id: "", using: FileManager())
            ?? Entry(id: "", name: home.lastPathComponent, usage: .unknown, children: nil)
        let documents = region("Documents", in: root)
        let library = region("Library", in: root)
        let libraryRegions = separateLibraryRegions.map { region($0, in: library, name: "Library/\($0)") }
        let remainingLibrary = library.children.map { children in
            Entry.directory(id: library.id, name: "Library（其余）", children: children.filter {
                !separateLibraryRegions.contains($0.name)
            })
        } ?? Entry(id: library.id, name: "Library（其余）", usage: library.usage, children: nil)
        let additionalRegions = root.children?.filter { !primaryRegions.contains($0.name) } ?? []
        let regions = [documents] + libraryRegions + [remainingLibrary, region("tmp", in: root)] + additionalRegions

        let chat = region("ZeChat", in: library)
        let database = Usage.sum(databaseFiles.map { chat.child(named: $0)?.usage ?? chat.missingChildUsage })
        let ze = region("ze", in: chat)
        let zeSizes = Dictionary(uniqueKeysWithValues: (ze.children ?? []).map { ($0.name, $0.usage) })
        let sessions = sessionIDs.reduce(into: [String: Usage]()) { sizes, id in
            sizes[id] = zeSizes[id] ?? ze.missingChildUsage
        }
        return Snapshot(
            regions: regions,
            shell: documents.child(named: "alpine-rootfs")?.usage ?? documents.missingChildUsage,
            database: database,
            sessions: sessions,
            total: .sum(regions.map(\.usage))
        )
    }

    private static func region(_ component: String, in parent: Entry, name: String? = nil) -> Entry {
        let entry = parent.child(named: component)
        return Entry(
            id: parent.id + "/" + component,
            name: name ?? component,
            usage: entry?.usage ?? parent.missingChildUsage,
            children: entry?.children
        )
    }

    private static func measure(_ url: URL, id: String, using fm: FileManager) throws -> Entry? {
        try Task.checkCancellation()
        let name = url.lastPathComponent
        let unavailable = Entry(id: id, name: name, usage: .unknown, children: nil)
        guard let values = try? url.resourceValues(forKeys: keys) else { return unavailable }
        if values.isSymbolicLink == true { return nil }
        guard values.isSymbolicLink == false else { return unavailable }
        if values.isDirectory == true {
            guard let items = try? fm.contentsOfDirectory(at: url, includingPropertiesForKeys: prefetchKeys, options: []) else {
                return unavailable
            }
            let children = try items.compactMap { try measure($0, id: id + "/" + $0.lastPathComponent, using: fm) }
            return .directory(id: id, name: name, children: children)
        }
        if values.isRegularFile == true {
            guard let size = values.totalFileSize ?? values.fileSize else { return unavailable }
            return Entry(id: id, name: name, usage: Usage(bytes: Int64(size)), children: nil)
        }
        guard values.isDirectory == false, values.isRegularFile == false else { return unavailable }
        return nil
    }
}
