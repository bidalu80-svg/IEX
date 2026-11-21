import Foundation
import UniformTypeIdentifiers

final class ShareViewModel {
    struct Result {
        var saved = 0
        var failed = 0
    }

    private enum LoadedItem {
        case file(saved: Bool)
        case text(String, isLink: Bool)
    }

    func receive(_ items: [NSExtensionItem], in inbox: PendingShareInbox) async -> Result {
        var result = Result()
        for provider in items.flatMap({ $0.attachments ?? [] }) {
            if await receive(provider, in: inbox) {
                result.saved += 1
            } else {
                result.failed += 1
            }
        }
        return result
    }

    private func receive(_ provider: NSItemProvider, in inbox: PendingShareInbox) async -> Bool {
        let types = provider.registeredTypeIdentifiers
        let suggestedName = provider.suggestedName.map { ($0 as NSString).lastPathComponent }
            .flatMap { $0.isEmpty ? nil : $0 }
        let canLoadPlainText = provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier)
        let suggestedFileName: String? = suggestedName.flatMap { name in
            canLoadPlainText || !(name as NSString).pathExtension.isEmpty ? name : nil
        }
        var fileFailed = false
        var deferredText: LoadedItem?
        func record(_ item: LoadedItem?) -> Bool {
            switch item {
            case .file(let saved):
                if !saved { fileFailed = true }
                return saved
            case .text:
                if deferredText == nil { deferredText = item }
            case nil:
                break
            }
            return false
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
           record(await loadItem(from: provider, type: .fileURL, onFailure: .file(saved: false), receive: { item in
               guard let url = Self.representedURL(item), url.isFileURL else { return .file(saved: false) }
               return .file(saved: (try? Self.copyFileURL(url, suggestedFileName: suggestedFileName, into: inbox)) != nil)
           })) { return true }

        let generic = Set([UTType.item.identifier, UTType.content.identifier, UTType.data.identifier])
        let inlineTextTypes: [UTType] = [.text, .plainText, .utf8PlainText, .utf16PlainText, .utf16ExternalPlainText]
        let inlineTextIdentifiers = Set(inlineTextTypes.map(\.identifier))
        let openInPlaceIdentifiers = Set(provider.registeredTypeIdentifiers(fileOptions: .openInPlace))
        let fileTypes = types.filter { identifier in
            if openInPlaceIdentifiers.contains(identifier) { return true }
            guard UTType(identifier)?.conforms(to: .url) != true else { return false }
            return !inlineTextIdentifiers.contains(identifier) || suggestedFileName != nil
        }
        let rankedFileTypes = fileTypes.filter { !generic.contains($0) } + fileTypes.filter { generic.contains($0) }
        func fileFailure(for identifier: String) -> LoadedItem? {
            openInPlaceIdentifiers.contains(identifier) ? .file(saved: false) : nil
        }
        for identifier in rankedFileTypes {
            if record(await loadFile(from: provider, identifier: identifier, suggestedFileName: suggestedFileName,
                                     onFailure: fileFailure(for: identifier), into: inbox)) { return true }
        }

        if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier),
           record(await loadItem(from: provider, type: .url, receive: { item in
               guard let url = Self.representedURL(item) else { return nil }
               if url.isFileURL {
                   return .file(saved: (try? Self.copyFileURL(url, suggestedFileName: suggestedFileName, into: inbox)) != nil)
               }
               return .text(url.absoluteString, isLink: true)
           })) { return true }

        if canLoadPlainText,
           record(await loadItem(from: provider, type: .plainText, receive: { item in
               if let url = item as? URL, url.isFileURL {
                   return .file(saved: (try? Self.copyFileURL(url, suggestedFileName: suggestedFileName, into: inbox)) != nil)
               }
               guard let text = item as? String, !text.isEmpty else { return nil }
               return .text(text, isLink: false)
           })) { return true }

        for identifier in rankedFileTypes {
            let onFailure = fileFailure(for: identifier)
            if record(await loadItem(from: provider, identifier: identifier, onFailure: onFailure, receive: { item in
                if let url = item as? URL, url.isFileURL {
                    return .file(saved: (try? Self.copyFileURL(url, suggestedFileName: suggestedFileName, into: inbox)) != nil)
                }
                guard let data = item as? Data else { return nil }
                let baseName = suggestedName ?? "Shared File"
                let suffix = UTType(identifier)?.preferredFilenameExtension
                let name = suggestedFileName ?? suffix.map { "\(baseName).\($0)" } ?? baseName
                let saved = try? inbox.storeFile(named: name) { try data.write(to: $0) }
                return saved != nil ? .file(saved: true) : onFailure
            })) { return true }
        }

        guard !fileFailed, case .text(let text, let isLink)? = deferredText else { return false }
        if isLink || text.count <= 1000 { return (try? inbox.storeText(text)) != nil }
        return (try? inbox.storeFile(named: "Shared Text.txt") { destination in
            try text.write(to: destination, atomically: true, encoding: .utf8)
        }) != nil
    }

    private func loadFile(from provider: NSItemProvider, identifier: String, suggestedFileName: String?,
                          onFailure: LoadedItem?, into inbox: PendingShareInbox) async -> LoadedItem? {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: identifier) { url, error in
                guard error == nil, let url, url.isFileURL else {
                    continuation.resume(returning: onFailure)
                    return
                }
                let name = suggestedFileName ?? url.lastPathComponent
                let saved = try? inbox.storeFile(named: name) { destination in
                    try PendingShareInbox.copyRegularFile(at: url, to: destination)
                }
                continuation.resume(returning: saved != nil ? .file(saved: true) : onFailure)
            }
        }
    }

    private func loadItem(from provider: NSItemProvider, type: UTType, onFailure: LoadedItem? = nil,
                          receive: @escaping (NSSecureCoding?) -> LoadedItem?) async -> LoadedItem? {
        await loadItem(from: provider, identifier: type.identifier, onFailure: onFailure, receive: receive)
    }

    private func loadItem(from provider: NSItemProvider, identifier: String, onFailure: LoadedItem? = nil,
                          receive: @escaping (NSSecureCoding?) -> LoadedItem?) async -> LoadedItem? {
        await withCheckedContinuation { continuation in
            provider.loadItem(forTypeIdentifier: identifier, options: nil) { item, error in
                continuation.resume(returning: error == nil ? receive(item) : onFailure)
            }
        }
    }

    private static func copyFileURL(_ url: URL, suggestedFileName: String?, into inbox: PendingShareInbox) throws -> PendingShare {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        return try inbox.storeFile(named: suggestedFileName ?? url.lastPathComponent) { destination in
            var coordinationError: NSError?
            var copyResult: Swift.Result<Void, Error>?
            NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordinationError) { readableURL in
                copyResult = Swift.Result { try PendingShareInbox.copyRegularFile(at: readableURL, to: destination) }
            }
            if let coordinationError { throw coordinationError }
            guard let copyResult else { throw CocoaError(.fileReadUnknown) }
            try copyResult.get()
        }
    }

    private static func representedURL(_ item: NSSecureCoding?) -> URL? {
        if let url = item as? URL { return url }
        if let data = item as? Data { return URL(dataRepresentation: data, relativeTo: nil) }
        return nil
    }
}
