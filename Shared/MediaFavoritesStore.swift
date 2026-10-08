import Foundation
import UIKit
import AVFoundation
import Combine

/// Media categories supported by the persistent Favorites library.
enum FavoriteMediaKind: String, Codable, CaseIterable, Identifiable {
    case image
    case video
    case audio

    var id: String { rawValue }
    var title: String {
        switch self {
        case .image: return "图片"
        case .video: return "视频"
        case .audio: return "音频"
        }
    }
    var icon: String {
        switch self {
        case .image: return "photo"
        case .video: return "film"
        case .audio: return "waveform"
        }
    }
}

struct FavoriteMediaItem: Identifiable, Codable, Equatable {
    let id: UUID
    let fileName: String
    let kind: FavoriteMediaKind
    let createdAt: Date
    /// The original ze:// URL or file path. It is informational and also
    /// prevents the same message attachment from being copied repeatedly.
    let sourceKey: String?
}

extension InputAttachment {
    var favoriteMediaKind: FavoriteMediaKind? {
        let ext = cacheURL.pathExtension.lowercased()
        if ["jpg", "jpeg", "png", "gif", "webp", "heic", "bmp", "tiff"].contains(ext) { return .image }
        if ["mp4", "mov", "m4v", "avi", "mkv", "webm"].contains(ext) { return .video }
        if ["mp3", "m4a", "wav", "aac", "ogg", "flac"].contains(ext) { return .audio }
        return nil
    }
}

extension AttachmentMeta {
    var isAudio: Bool {
        ["mp3", "m4a", "wav", "aac", "ogg", "flac"].contains((path as NSString).pathExtension.lowercased())
    }

    var favoriteMediaKind: FavoriteMediaKind? {
        if isImage { return .image }
        if isVideo { return .video }
        if isAudio { return .audio }
        return nil
    }
}

/// A small, durable media library. Favorites are copied into the app's
/// Library/ZeChat/favorites directory, so deleting a conversation or its
/// attachment cannot remove a user's saved item.
@MainActor
final class MediaFavoritesStore: ObservableObject {
    static let shared = MediaFavoritesStore()

    @Published private(set) var items: [FavoriteMediaItem] = []

    private let fm = FileManager.default
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    private init() {
        encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        load()
    }

    private var libraryURL: URL {
        fm.urls(for: .libraryDirectory, in: .userDomainMask).first!
    }

    private var rootURL: URL {
        libraryURL.appendingPathComponent("ZeChat/favorites/media", isDirectory: true)
    }

    private var metadataURL: URL {
        rootURL.appendingPathComponent("index.json")
    }

    func fileURL(for item: FavoriteMediaItem) -> URL {
        rootURL
            .appendingPathComponent(item.id.uuidString, isDirectory: true)
            .appendingPathComponent(item.fileName)
    }

    @discardableResult
    func add(fileURL: URL, kind: FavoriteMediaKind, fileName: String? = nil, sourceKey: String? = nil) -> FavoriteMediaItem? {
        guard fm.fileExists(atPath: fileURL.path) else { return nil }
        if let sourceKey, let existing = items.first(where: { $0.sourceKey == sourceKey }) {
            return existing
        }

        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            let id = UUID()
            let name = Self.sanitizedFileName(fileName ?? fileURL.lastPathComponent, fallback: "媒体文件")
            let item = FavoriteMediaItem(id: id, fileName: name, kind: kind, createdAt: Date(), sourceKey: sourceKey)
            let destinationDirectory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            try fm.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
            try fm.copyItem(at: fileURL, to: fileURL(for: item))
            items.insert(item, at: 0)
            save()
            return item
        } catch {
            return nil
        }
    }

    func remove(_ item: FavoriteMediaItem) {
        try? fm.removeItem(at: rootURL.appendingPathComponent(item.id.uuidString, isDirectory: true))
        items.removeAll { $0.id == item.id }
        save()
    }

    func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for item in items where ids.contains(item.id) {
            try? fm.removeItem(at: rootURL.appendingPathComponent(item.id.uuidString, isDirectory: true))
        }
        items.removeAll { ids.contains($0.id) }
        save()
    }

    func makeZip(for selected: [FavoriteMediaItem]) async -> URL? {
        guard !selected.isEmpty else { return nil }
        let stageURL = fm.temporaryDirectory.appendingPathComponent("ze-favorites-stage-\(UUID().uuidString)", isDirectory: true)
        let archiveURL = fm.temporaryDirectory.appendingPathComponent("Ze收藏夹-\(UUID().uuidString.prefix(8)).zip")

        do {
            try fm.createDirectory(at: stageURL, withIntermediateDirectories: true)
            for item in selected {
                let source = fileURL(for: item)
                let stagedName = "\(item.id.uuidString.prefix(8))_\(item.fileName)"
                try fm.copyItem(at: source, to: stageURL.appendingPathComponent(stagedName))
            }

            // NSFileCoordinator's .forUploading produces a standard compressed
            // ZIP package on iOS. Keep the manual writer as a dependency-free
            // fallback for unusual file-provider implementations.
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                let coordinator = NSFileCoordinator()
                var coordinationError: NSError?
                var finished = false
                func finish(_ result: Result<Void, Error>) {
                    guard !finished else { return }
                    finished = true
                    continuation.resume(with: result)
                }
                coordinator.coordinate(readingItemAt: stageURL, options: .forUploading, error: &coordinationError) { zippedURL in
                    do {
                        try fm.copyItem(at: zippedURL, to: archiveURL)
                        finish(.success(()))
                    } catch {
                        finish(.failure(error))
                    }
                }
                if let coordinationError { finish(.failure(coordinationError)) }
            }
            try? fm.removeItem(at: stageURL)
            return archiveURL
        } catch {
            try? fm.removeItem(at: stageURL)
            let entries = selected.map { (fileURL(for: $0), $0.fileName) }
            guard let data = try? Self.makeStoredZip(items: entries) else { return nil }
            try? data.write(to: archiveURL, options: .atomic)
            return fm.fileExists(atPath: archiveURL.path) ? archiveURL : nil
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: metadataURL),
              let decoded = try? decoder.decode([FavoriteMediaItem].self, from: data) else {
            items = []
            return
        }
        items = decoded.filter { fm.fileExists(atPath: fileURL(for: $0).path) }
    }

    private func save() {
        do {
            try fm.createDirectory(at: rootURL, withIntermediateDirectories: true)
            try encoder.encode(items).write(to: metadataURL, options: .atomic)
        } catch {
            // The UI remains usable if a metadata write is temporarily interrupted.
        }
    }

    private static func sanitizedFileName(_ raw: String, fallback: String) -> String {
        let name = raw.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "\\", with: "_")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? fallback : name
    }

    // Standard ZIP container with UTF-8 names. Entries are stored verbatim;
    // this keeps the implementation dependency-free on iOS while still
    // producing a shareable .zip archive accepted by Files and macOS.
    private static func makeStoredZip(items: [(URL, String)]) throws -> Data {
        var local = Data()
        var central = Data()
        var count: UInt16 = 0

        for (url, name) in items {
            let data = try Data(contentsOf: url)
            let nameData = name.data(using: .utf8) ?? Data("media".utf8)
            let crc = crc32(data)
            let offset = UInt32(local.count)
            local.appendLE(UInt32(0x04034b50))
            local.appendLE(UInt16(20)); local.appendLE(UInt16(0x800)); local.appendLE(UInt16(0))
            local.appendLE(UInt16(0)); local.appendLE(UInt16(0))
            local.appendLE(crc); local.appendLE(UInt32(data.count)); local.appendLE(UInt32(data.count))
            local.appendLE(UInt16(nameData.count)); local.appendLE(UInt16(0))
            local.append(nameData); local.append(data)

            central.appendLE(UInt32(0x02014b50))
            central.appendLE(UInt16(20)); central.appendLE(UInt16(20)); central.appendLE(UInt16(0x800)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(crc); central.appendLE(UInt32(data.count)); central.appendLE(UInt32(data.count))
            central.appendLE(UInt16(nameData.count)); central.appendLE(UInt16(0)); central.appendLE(UInt16(0))
            central.appendLE(UInt16(0)); central.appendLE(UInt16(0)); central.appendLE(UInt32(0)); central.appendLE(offset)
            central.append(nameData)
            count &+= 1
        }

        var output = local
        let centralOffset = UInt32(local.count)
        output.append(central)
        output.appendLE(UInt32(0x06054b50))
        output.appendLE(UInt16(0)); output.appendLE(UInt16(0)); output.appendLE(count); output.appendLE(count)
        output.appendLE(UInt32(central.count)); output.appendLE(centralOffset); output.appendLE(UInt16(0))
        return output
    }

    private static func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = 0xffffffff
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 {
                crc = (crc >> 1) ^ ((crc & 1) == 1 ? 0xedb88320 : 0)
            }
        }
        return crc ^ 0xffffffff
    }
}

private extension Data {
    mutating func appendLE(_ value: UInt16) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff))
    }
    mutating func appendLE(_ value: UInt32) {
        append(UInt8(value & 0xff)); append(UInt8((value >> 8) & 0xff)); append(UInt8((value >> 16) & 0xff)); append(UInt8((value >> 24) & 0xff))
    }
}

