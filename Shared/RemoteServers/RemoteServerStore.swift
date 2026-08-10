import Foundation
import SwiftUI

/// Stores non-secret SSH server metadata in Application Support. This file is
/// intentionally separate from MCP, Rootfs, chat history, and iCloud sync.
@MainActor
final class RemoteServerStore: ObservableObject {
    static let shared = RemoteServerStore()

    @Published private(set) var servers: [RemoteServerProfile] = []

    private let fileManager = FileManager.default
    private let logger = AppLogger(category: "RemoteServers")

    private init() {
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: storageURL) else {
            servers = []
            return
        }
        do {
            servers = try JSONDecoder.remoteServers.decode([RemoteServerProfile].self, from: data)
                .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        } catch {
            logger.error("Could not decode remote server profiles: \(error.localizedDescription)")
            servers = []
        }
    }

    func server(id: UUID) -> RemoteServerProfile? {
        servers.first(where: { $0.id == id })
    }

    func save(_ proposed: RemoteServerProfile) throws {
        var server = normalized(proposed)
        guard !server.name.isEmpty else { throw RemoteServerError.invalidProfile("名称不能为空") }
        guard !server.normalizedHost.isEmpty else { throw RemoteServerError.invalidProfile("主机不能为空") }
        guard (1...65_535).contains(server.port) else { throw RemoteServerError.invalidProfile("端口必须在 1 到 65535 之间") }
        guard !server.username.isEmpty else { throw RemoteServerError.invalidProfile("用户名不能为空") }

        if let index = servers.firstIndex(where: { $0.id == server.id }) {
            let existing = servers[index]
            // A confirmed key only identifies one host/port pair. Never carry
            // it to a changed endpoint, even if the user keeps the same name.
            if existing.normalizedHost != server.normalizedHost || existing.port != server.port {
                server.knownHost = nil
            }
            server.createdAt = existing.createdAt
            server.lastConnectedAt = existing.lastConnectedAt
            servers[index] = server
        } else {
            servers.append(server)
        }
        servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        try persist()
    }

    func delete(_ server: RemoteServerProfile) throws {
        servers.removeAll(where: { $0.id == server.id })
        try persist()
        RemoteServerSecretStore.deleteAll(for: server.id)
        RemoteServerSessionCredentials.shared.clear(for: server.id)
    }

    func setKnownHost(_ knownHost: RemoteKnownHost, for serverID: UUID) throws {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].knownHost = knownHost
        servers[index].updatedAt = .now
        try persist()
    }

    func markConnected(_ serverID: UUID) throws {
        guard let index = servers.firstIndex(where: { $0.id == serverID }) else { return }
        servers[index].lastConnectedAt = .now
        try persist()
    }

    private func normalized(_ proposed: RemoteServerProfile) -> RemoteServerProfile {
        var server = proposed
        server.name = server.name.trimmingCharacters(in: .whitespacesAndNewlines)
        server.host = server.host.trimmingCharacters(in: .whitespacesAndNewlines)
        server.username = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        server.labels = Array(Set(server.labels
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        server.note = server.note.trimmingCharacters(in: .whitespacesAndNewlines)
        server.updatedAt = .now
        return server
    }

    private func persist() throws {
        let directory = storageURL.deletingLastPathComponent()
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONEncoder.remoteServers.encode(servers)
        try data.write(to: storageURL, options: .atomic)
    }

    private var storageURL: URL {
        fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ze", isDirectory: true)
            .appendingPathComponent("RemoteServers", isDirectory: true)
            .appendingPathComponent("servers.json")
    }
}

private extension JSONEncoder {
    static var remoteServers: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }
}

private extension JSONDecoder {
    static var remoteServers: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
