import Foundation
import SwiftUI

struct RemoteDisk: Codable, Identifiable, Hashable {
    var profile: RemoteStorageProfile
    /// SFTP reuses the existing SSH credential and host-trust editor/store.
    var sshServerID: UUID?
    // Changes on every save, including credential-only edits.
    var configurationRevision: UUID
    var id: UUID { profile.id }

    init(profile: RemoteStorageProfile, sshServerID: UUID? = nil) {
        self.profile = profile; self.sshServerID = sshServerID
        configurationRevision = UUID()
    }

    private enum CodingKeys: String, CodingKey { case profile, sshServerID, configurationRevision }
    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        profile = try values.decode(RemoteStorageProfile.self, forKey: .profile)
        sshServerID = try values.decodeIfPresent(UUID.self, forKey: .sshServerID)
        configurationRevision = try values.decodeIfPresent(UUID.self, forKey: .configurationRevision) ?? UUID()
    }
}

struct RemoteDiskVerification: Codable {
    var connection = "未验证"
    var listing = "未验证"
    var reading = "未验证"
    var checkedAt: Date?
    var sshUpdatedAt: Date?
}

enum RemoteDiskError: LocalizedError {
    case invalidAddress
    case missingDisk
    case readOnly
    case invalidConfiguration(String)
    var errorDescription: String? {
        switch self {
        case .invalidAddress: return "网络磁盘地址无效；不允许越界路径、凭据或查询参数"
        case .missingDisk: return "网络磁盘已删除或不存在"
        case .readOnly: return "网络磁盘为只读，禁止写入、删除、重命名或创建目录"
        case .invalidConfiguration(let detail): return detail
        }
    }
}

/// One percent-decoding pass, performed per component. URL.path's implicit
/// normalization must never turn encoded separators or dot segments into access.
struct RemoteDiskAddress: Hashable {
    let diskID: UUID
    let components: [String]

    init(_ raw: String) throws {
        guard let url = URLComponents(string: raw), url.scheme?.lowercased() == "remote-disk",
              let host = url.host, let id = UUID(uuidString: host),
              url.user == nil, url.password == nil, url.port == nil, url.query == nil, url.fragment == nil else { throw RemoteDiskError.invalidAddress }
        let pieces = try url.percentEncodedPath.split(separator: "/", omittingEmptySubsequences: true).map { encoded -> String in
            guard let value = String(encoded).removingPercentEncoding else { throw RemoteDiskError.invalidAddress }
            try Self.validateComponent(value)
            return value
        }
        diskID = id; components = pieces
    }

    init(diskID: UUID, components: [String] = []) throws {
        for value in components { try Self.validateComponent(value) }
        self.diskID = diskID; self.components = components
    }

    static func validateComponent(_ value: String) throws {
        guard !value.isEmpty, value != ".", value != "..", !value.contains("/"), !value.contains("\\"),
              !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { throw RemoteDiskError.invalidAddress }
    }

    var string: String { "remote-disk://" + diskID.uuidString.lowercased() + "/" + components.map(RemoteStorageEndpoint.encode).joined(separator: "/") }
    func child(_ name: String) throws -> RemoteDiskAddress { try .init(diskID: diskID, components: components + [name]) }
    var parent: RemoteDiskAddress { try! .init(diskID: diskID, components: Array(components.dropLast())) }

    func serverPath(root: String) throws -> String {
        let rootParts = root.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for part in rootParts { try Self.validateComponent(part) }
        return "/" + (rootParts + components).joined(separator: "/")
    }
}

@MainActor
final class RemoteDiskStore: ObservableObject {
    static let shared = RemoteDiskStore()
    @Published private(set) var disks: [RemoteDisk] = []
    @Published private(set) var verification: [UUID: RemoteDiskVerification] = [:]
    @Published private(set) var loadError: String?
    private let url: URL
    private struct State: Codable { var disks: [RemoteDisk]; var verification: [UUID: RemoteDiskVerification] }

    private init() {
        url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Ze/RemoteDisks/disks.json")
        do {
            if FileManager.default.fileExists(atPath: url.path) {
                let state = try JSONDecoder().decode(State.self, from: Data(contentsOf: url))
                disks = state.disks; verification = state.verification
            }
        } catch { loadError = "网络磁盘配置读取失败：" + error.localizedDescription }
    }

    func disk(id: UUID) throws -> RemoteDisk {
        guard let disk = disks.first(where: { $0.id == id }) else { throw RemoteDiskError.missingDisk }
        return disk
    }

    func save(_ proposed: RemoteDisk, secret: String?) throws {
        var disk = proposed; disk.configurationRevision = UUID()
        guard loadError == nil else { throw RemoteDiskError.invalidConfiguration(loadError!) }
        let p = disk.profile
        guard !p.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw RemoteDiskError.invalidConfiguration("名称不能为空") }
        _ = try RemoteStorageEndpoint.components(p)
        _ = try RemoteDiskAddress(diskID: p.id).serverPath(root: p.path)
        if p.proto == .sftp {
            guard let id = disk.sshServerID, RemoteServerStore.shared.server(id: id) != nil else { throw RemoteDiskError.invalidConfiguration("请选择 SSH 服务器") }
        }
        let old = disks; let oldVerification = verification
        // Write credentials first: failure must not publish a usable profile.
        let oldSecret: String? = try secret.map { _ in try RemoteServerSecretStore.value(kind: .remoteSecret, for: p.id) } ?? nil
        if let secret { try RemoteServerSecretStore.save(secret, kind: .remoteSecret, for: p.id) }
        if let index = disks.firstIndex(where: { $0.id == p.id }) { disks[index] = disk } else { disks.append(disk) }
        verification[p.id] = RemoteDiskVerification()
        do { try persist() } catch {
            disks = old; verification = oldVerification
            if secret != nil {
                if let oldSecret { try RemoteServerSecretStore.save(oldSecret, kind: .remoteSecret, for: p.id) }
                else { RemoteServerSecretStore.delete(kind: .remoteSecret, for: p.id) }
            }
            throw error
        }
    }

    func remove(_ disk: RemoteDisk) throws {
        let old = disks; let oldVerification = verification
        disks.removeAll { $0.id == disk.id }; verification.removeValue(forKey: disk.id)
        do { try persist() } catch { disks = old; verification = oldVerification; throw error }
        RemoteServerSecretStore.delete(kind: .remoteSecret, for: disk.id)
    }

    func status(for disk: RemoteDisk) -> RemoteDiskVerification {
        let result = verification[disk.id] ?? RemoteDiskVerification()
        if disk.profile.proto == .sftp {
            guard let id = disk.sshServerID, let server = RemoteServerStore.shared.server(id: id),
                  result.sshUpdatedAt == server.updatedAt else { return RemoteDiskVerification() }
        }
        return result
    }

    /// Fail closed before a write-only credential change, without reading the
    /// old Keychain value. In-flight results retain the old revision and fail.
    func invalidateCredentialVerification(diskID: UUID) throws {
        guard loadError == nil, let index = disks.firstIndex(where: { $0.id == diskID }) else {
            throw RemoteDiskError.missingDisk
        }
        disks[index].configurationRevision = UUID()
        verification.removeValue(forKey: diskID)
        try persist()
    }

    func clearSSHVerification(serverID: UUID) throws {
        guard loadError == nil else { throw RemoteDiskError.invalidConfiguration(loadError!) }
        for disk in disks where disk.profile.proto == .sftp && disk.sshServerID == serverID {
            verification.removeValue(forKey: disk.id)
        }
        // Do not restore stale successes on a persistence failure. The server
        // revision also makes an old on-disk result invalid after a reload.
        try persist()
    }

    func sshRevision(for disk: RemoteDisk) -> Date? {
        disk.sshServerID.flatMap { RemoteServerStore.shared.server(id: $0)?.updatedAt }
    }

    func record(_ result: RemoteDiskVerification, for disk: RemoteDisk) throws {
        // Ignore results from a request that outlived editing/removing its disk.
        guard disks.contains(disk) else { return }
        let old = verification
        guard disk.profile.proto != .sftp || result.sshUpdatedAt == sshRevision(for: disk) else { return }
        verification[disk.id] = result
        do { try persist() } catch { verification = old; throw error }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(State(disks: disks, verification: verification)).write(to: url, options: .atomic)
    }
}
