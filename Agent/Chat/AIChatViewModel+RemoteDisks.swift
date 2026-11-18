import Foundation

extension AIChatViewModel {
    static func isRemoteDiskPath(_ path: String) -> Bool { path.lowercased().hasPrefix("remote-disk:") }

    func remoteDiskToolDefinitions() -> [AgentToolDefinition] {
        [.init(name: "remote_disk_list",
            description: "List configured read-only network disks, or list a directory using its remote-disk:// address. No credentials accepted. Use file_read on returned file addresses; binary/media reads return a session-local path for read_image or other media tools. Writes are prohibited.",
            parameters: [
                "path": .init(type: .string, description: "Omit to list disks; otherwise use the exact remote-disk://UUID/path returned by this tool."),
                "offset": .init(type: .integer, description: "Directory page offset, default 0."),
                "limit": .init(type: .integer, description: "Maximum entries, default 200, at most 1000.")
            ], required: [])]
    }

    func executeRemoteDiskList(_ arguments: [String: Any]) async -> FileToolResult {
        do {
            let output: [String: Any]
            if let raw = arguments["path"] as? String, !raw.isEmpty {
                let address = try RemoteDiskAddress(raw)
                let entries = try await RemoteDiskService.shared.list(address)
                let offset = min(max(0, arguments["offset"] as? Int ?? 0), entries.count)
                let limit = min(max(1, arguments["limit"] as? Int ?? 200), 1000)
                let end = offset + min(limit, entries.count - offset)
                let rows: [[String: Any]] = entries[offset..<end].map {
                    var row: [String: Any] = ["name": $0.name, "path": $0.address.string, "is_directory": $0.isDirectory, "read_only": true]
                    if let size = $0.size { row["size"] = size }
                    return row
                }
                var page: [String: Any] = ["path": address.string, "entries": rows, "total": entries.count]
                if end < entries.count { page["next_offset"] = end }
                output = page
            } else {
                if let error = RemoteDiskStore.shared.loadError { throw RemoteDiskError.invalidConfiguration(error) }
                output = ["disks": try RemoteDiskStore.shared.disks.map { disk -> [String: Any] in
                    ["name": disk.profile.name, "protocol": disk.profile.proto.rawValue,
                     "path": try RemoteDiskAddress(diskID: disk.id).string, "read_only": true,
                     "read_verification": RemoteDiskStore.shared.status(for: disk).reading]
                }]
            }
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .prettyPrinted])
            return .init(output: String(decoding: data, as: UTF8.self), success: true)
        } catch { return .init(output: "网络磁盘读取失败：" + error.localizedDescription, success: false) }
    }

    /// Freeze the session identity before awaiting network I/O; downloads must
    /// stay in the requesting session even when the foreground chat changes.
    func prepareRemoteDiskFile(_ path: String) async throws -> (url: URL, linuxPath: String) {
        let address = try RemoteDiskAddress(path)
        guard let sid = fileSystemSessionId, !sid.isEmpty else { throw RemoteDiskError.invalidConfiguration("读取远程文件需要一个活动会话") }
        let base = Self.zePersistentBase.appendingPathComponent(sid, isDirectory: true).appendingPathComponent("attachments/remote-disks", isDirectory: true)
        let url = try await RemoteDiskService.shared.cache(address, in: base)
        let linux = "/var/ze/attachments/remote-disks/" + url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent
        return (url, linux)
    }
}

extension AIChatViewModel {
    /// Enter the existing attachment cache/classification/send path. Its image
    /// classification feeds imageData parts; documents retain a readable path;
    /// video and audio keep their original extension for local previews.
    func addRemoteDiskAttachment(from url: URL) throws {
        let count = attachments.count
        addFileAttachment(from: url)
        guard attachments.count == count + 1, let attachment = attachments.last,
              FileManager.default.fileExists(atPath: attachment.cacheURL.path) else {
            throw RemoteDiskError.invalidConfiguration("附件缓存写入失败，请重试")
        }
    }
}
