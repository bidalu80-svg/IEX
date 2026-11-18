import Foundation

/// The disk surface deliberately has no upload, command or mutation methods.
@MainActor
protocol RemoteDiskReading {
    func testConnection(_ disk: RemoteDisk) async throws
    func list(_ address: RemoteDiskAddress) async throws -> [RemoteDiskEntry]
    func download(_ address: RemoteDiskAddress, maximumBytes: Int) async throws -> Data
}

struct RemoteDiskEntry: Identifiable {
    let address: RemoteDiskAddress
    let name: String
    let isDirectory: Bool
    let size: UInt64?
    var id: String { address.string + (isDirectory ? "#directory" : "#file") }
}

@MainActor
final class RemoteDiskService: RemoteDiskReading {
    static let shared = RemoteDiskService()
    /// Independent of file_read's 80,000-character output cap.
    static let maximumDownloadBytes = 64 * 1024 * 1024
    private let store = RemoteDiskStore.shared

    private func client(_ disk: RemoteDisk) throws -> any RemoteStorageClient {
        let password = try RemoteServerSecretStore.value(kind: .remoteSecret, for: disk.id) ?? ""
        switch disk.profile.proto {
        case .webdav: return try WebDAVRemoteStorageClient(profile: disk.profile, password: password)
        case .smb: return try SMBRemoteStorageClient(profile: disk.profile, password: password)
        case .s3: return try S3RemoteStorageClient(profile: disk.profile, secret: password)
        case .ftp: return try FTPRemoteStorageClient(profile: disk.profile, password: password)
        case .sftp: throw RemoteDiskError.invalidConfiguration("SFTP 使用 SSH 只读适配器")
        }
    }

    private func ssh(_ disk: RemoteDisk) async throws -> UUID {
        guard let id = disk.sshServerID, let server = RemoteServerStore.shared.server(id: id) else { throw RemoteDiskError.invalidConfiguration("SSH 服务器已删除，请编辑磁盘重新选择") }
        guard server.enabled else { throw RemoteServerError.operationNotPermitted }
        try await RemoteSSHConnectionService.shared.ensureReadOnlyConnection(to: server)
        return id
    }

    func testConnection(_ disk: RemoteDisk) async throws {
        if disk.profile.proto == .sftp {
            let id = try await ssh(disk)
            do { _ = try await RemoteSSHConnectionService.shared.readOnlyPath(
                RemoteDiskAddress(diskID: disk.id).serverPath(root: disk.profile.path),
                root: RemoteDiskAddress(diskID: disk.id).serverPath(root: disk.profile.path), on: id) }
            catch { await RemoteSSHConnectionService.shared.disconnect(serverID: id); throw error }
        } else { try await client(disk).testConnection() }
    }

    func list(_ address: RemoteDiskAddress) async throws -> [RemoteDiskEntry] {
        let disk = try store.disk(id: address.diskID)
        let sshRevision = store.sshRevision(for: disk)
        let path = try address.serverPath(root: disk.profile.path)
        let entries: [RemoteSFTPEntry]
        if disk.profile.proto == .sftp {
            let id = try await ssh(disk)
            do {
                let confined = try await RemoteSSHConnectionService.shared.readOnlyPath(path, root: RemoteDiskAddress(diskID: disk.id).serverPath(root: disk.profile.path), on: id)
                entries = try await RemoteSSHConnectionService.shared.listDirectory(at: confined, on: id)
            } catch { await RemoteSSHConnectionService.shared.disconnect(serverID: id); throw error }
        } else { entries = try await client(disk).list(path: path) }
        guard try store.disk(id: disk.id) == disk, store.sshRevision(for: disk) == sshRevision else { throw RemoteDiskError.invalidConfiguration("磁盘配置已变化，请重新读取") }
        return try entries.filter { $0.name != "." && $0.name != ".." }.map { entry in
            RemoteDiskEntry(address: try address.child(entry.name), name: entry.name, isDirectory: entry.isDirectory, size: entry.size)
        }.sorted { $0.isDirectory != $1.isDirectory ? $0.isDirectory : $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func download(_ address: RemoteDiskAddress, maximumBytes: Int = maximumDownloadBytes) async throws -> Data {
        guard !address.components.isEmpty else { throw RemoteDiskError.invalidAddress }
        let limit = min(maximumBytes, Self.maximumDownloadBytes)
        guard limit > 0 else { throw RemoteDiskError.invalidConfiguration("下载上限必须大于零") }
        let disk = try store.disk(id: address.diskID)
        let sshRevision = store.sshRevision(for: disk)
        let path = try address.serverPath(root: disk.profile.path)
        let data: Data
        if disk.profile.proto == .sftp {
            let id = try await ssh(disk)
            do {
                let confined = try await RemoteSSHConnectionService.shared.readOnlyPath(path, root: RemoteDiskAddress(diskID: disk.id).serverPath(root: disk.profile.path), on: id)
                data = try await RemoteSSHConnectionService.shared.downloadFile(at: confined, on: id, maximumBytes: limit)
            } catch { await RemoteSSHConnectionService.shared.disconnect(serverID: id); throw error }
        } else {
            let adapter = try client(disk)
            switch adapter {
            case let dav as WebDAVRemoteStorageClient: data = try await dav.download(path: path, maximumBytes: limit)
            case let s3 as S3RemoteStorageClient: data = try await s3.download(path: path, maximumBytes: limit)
            case let ftp as FTPRemoteStorageClient: data = try await ftp.download(path: path, maximumBytes: limit)
            case let smb as SMBRemoteStorageClient: data = try await smb.download(path: path, maximumBytes: limit)
            default: throw RemoteDiskError.invalidConfiguration("此协议没有受限读取实现")
            }
        }
        guard try store.disk(id: disk.id) == disk, store.sshRevision(for: disk) == sshRevision else { throw RemoteDiskError.invalidConfiguration("磁盘配置已变化，请重新读取") }
        return data
    }

    func cache(_ address: RemoteDiskAddress, in directory: URL) async throws -> URL {
        let data = try await download(address)
        let folder = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(address.components.last ?? "file")
        do { try data.write(to: file, options: .atomic); return file }
        catch { try? FileManager.default.removeItem(at: folder); throw error }
    }

    /// Verification performs three real operations. Reading never claims
    /// success for an empty directory, or for a directory containing only folders.
    func verify(_ disk: RemoteDisk, readAddress: RemoteDiskAddress? = nil) async -> RemoteDiskVerification {
        var result = RemoteDiskVerification(); result.checkedAt = .now
        result.sshUpdatedAt = store.sshRevision(for: disk)
        do { try await testConnection(disk); result.connection = "成功" }
        catch { result.connection = "失败：" + error.localizedDescription; return result }
        let entries: [RemoteDiskEntry]
        do { entries = try await list(RemoteDiskAddress(diskID: disk.id)); result.listing = "成功（\(entries.count) 项）" }
        catch { result.listing = "失败：" + error.localizedDescription; return result }
        guard let sample = readAddress ?? entries.first(where: { !$0.isDirectory && ($0.size ?? 0) <= 1024 * 1024 })?.address else {
            result.reading = "未验证：请选择一个文件验证读取"; return result
        }
        do { let data = try await download(sample); result.reading = "成功（\(data.count) 字节）" }
        catch { result.reading = "失败：" + error.localizedDescription }
        return result
    }
}
