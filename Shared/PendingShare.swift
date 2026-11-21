import Foundation

struct PendingShare: Codable, Equatable, Identifiable, Sendable {
    let id: UUID
    let receivedAt: Date
    let kind: Kind
    let value: String

    enum Kind: String, Codable, Sendable {
        case inlineText
        case attachment
    }
}

struct PendingShareInbox: Sendable {
    let directory: URL

    struct Receipt: Equatable, Identifiable {
        let share: PendingShare
        let directory: URL
        let fileURL: URL?

        var id: UUID { share.id }

        func remove() throws {
            let fileManager = FileManager.default
            let retired = directory.deletingLastPathComponent()
                .appendingPathComponent(".received-\(id.uuidString)", isDirectory: true)
            try fileManager.moveItem(at: directory, to: retired)
            try? fileManager.removeItem(at: retired)
        }
    }

    @discardableResult
    func storeText(_ text: String) throws -> PendingShare {
        try publish(.inlineText, value: text) { _ in }
    }

    @discardableResult
    func storeFile(named name: String, copyToDestination: (URL) throws -> Void) throws -> PendingShare {
        guard Self.isFileName(name) else { throw CocoaError(.fileWriteInvalidFileName) }
        return try publish(.attachment, value: name) { staging in
            let files = staging.appendingPathComponent("file", isDirectory: true)
            try FileManager.default.createDirectory(at: files, withIntermediateDirectories: false)
            let destination = files.appendingPathComponent(name, isDirectory: false)
            try copyToDestination(destination)
            try Self.requireRegularFile(destination)
        }
    }

    static func copyRegularFile(at source: URL, to destination: URL) throws {
        try requireRegularFile(source)
        try FileManager.default.copyItem(at: source, to: destination)
    }

    func receipts() -> [Receipt] {
        let fileManager = FileManager.default
        let directories = (try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil,
                                                               options: [.skipsHiddenFiles])) ?? []
        return directories.compactMap { entry in
            guard let id = UUID(uuidString: entry.lastPathComponent),
                  let data = try? Data(contentsOf: entry.appendingPathComponent("receipt.json")),
                  let share = try? JSONDecoder().decode(PendingShare.self, from: data), share.id == id else { return nil }
            switch share.kind {
            case .inlineText:
                return Receipt(share: share, directory: entry, fileURL: nil)
            case .attachment:
                guard Self.isFileName(share.value) else { return nil }
                let fileURL = entry.appendingPathComponent("file", isDirectory: true)
                    .appendingPathComponent(share.value, isDirectory: false)
                guard fileManager.isReadableFile(atPath: fileURL.path) else { return nil }
                return Receipt(share: share, directory: entry, fileURL: fileURL)
            }
        }
    }

    private func publish(_ kind: PendingShare.Kind, value: String, prepare: (URL) throws -> Void) throws -> PendingShare {
        let fileManager = FileManager.default
        let share = PendingShare(id: UUID(), receivedAt: Date(), kind: kind, value: value)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".writing-\(share.id.uuidString)", isDirectory: true)
        let final = directory.appendingPathComponent(share.id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? fileManager.removeItem(at: staging) }

        try prepare(staging)
        try JSONEncoder().encode(share).write(to: staging.appendingPathComponent("receipt.json"), options: .atomic)
        try fileManager.moveItem(at: staging, to: final)
        return share
    }

    private static func isFileName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    private static func requireRegularFile(_ url: URL) throws {
        let resource = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
        guard resource.isRegularFile == true, resource.isSymbolicLink != true else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
    }
}
