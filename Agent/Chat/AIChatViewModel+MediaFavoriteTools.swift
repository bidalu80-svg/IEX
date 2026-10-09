import Foundation
import UniformTypeIdentifiers
import ImageIO
import AVFoundation

struct MediaFavoriteToolResult { let output: String; let success: Bool }

extension AIChatViewModel {
    func mediaFavoriteToolDefinitions() -> [AgentToolDefinition] {
        let title = AgentToolParam(type: .string, description: "显示给用户的简短中文操作标题")
        return [
            AgentToolDefinition(name: "media_favorite_list", description: "列出用户收藏的图片、视频、音频，返回收藏 ID。用 kind 分类，用 offset 分页，不返回内部存储路径。",
                parameters: ["tool_title": title,
                    "kind": AgentToolParam(type: .string, description: "可选分类：image、video、audio；不填返回全部"),
                    "offset": AgentToolParam(type: .integer, description: "分页偏移，默认 0"),
                    "limit": AgentToolParam(type: .integer, description: "返回数量，默认 30，最多 100")],
                required: ["tool_title"], propertyOrdering: ["tool_title", "kind", "offset", "limit"]),
            AgentToolDefinition(name: "media_favorite_add", description: "把当前会话可访问的图片、视频或音频复制到持久收藏夹。path 使用 ze:// 媒体链接或 Linux 绝对路径；先确认文件存在，不接受远程 HTTP 链接。原会话文件保持不变。",
                parameters: ["tool_title": title, "path": AgentToolParam(type: .string, description: "媒体的 ze:// 链接或 Linux 绝对路径")],
                required: ["tool_title", "path"], propertyOrdering: ["tool_title", "path"]),
            AgentToolDefinition(name: "media_favorite_delete", description: "删除一个收藏夹副本，必须使用 media_favorite_list 返回的收藏 ID。界面确认后执行，不删除原会话媒体。",
                parameters: ["tool_title": title, "favorite_id": AgentToolParam(type: .string, description: "收藏 UUID，不是文件路径")],
                required: ["tool_title", "favorite_id"], propertyOrdering: ["tool_title", "favorite_id"])
        ]
    }

    func executeMediaFavoriteTool(name: String, arguments: [String: Any]) async -> MediaFavoriteToolResult {
        let store = MediaFavoritesStore.shared
        do {
            try Task.checkCancellation()
            switch name {
            case "media_favorite_list":
                var values = store.items
                if let raw = arguments["kind"] as? String {
                    guard let kind = FavoriteMediaKind(rawValue: raw) else { throw MediaFavoriteToolError.message("分类必须是 image、video 或 audio。") }
                    values = values.filter { $0.kind == kind }
                }
                let offset = min(max(arguments["offset"] as? Int ?? 0, 0), values.count)
                let limit = min(max(arguments["limit"] as? Int ?? 30, 1), 100)
                let rows = values.dropFirst(offset).prefix(limit).map(favoriteToolRow)
                return favoriteToolJSON(["favorites": rows, "total": values.count, "offset": offset])
            case "media_favorite_add":
                guard let path = arguments["path"] as? String,
                      path.hasPrefix("ze://") || path.hasPrefix("/"),
                      !path.unicodeScalars.contains(where: { $0.value < 32 }) else {
                    throw MediaFavoriteToolError.message("请传入 ze:// 媒体链接或 Linux 绝对路径。")
                }
                // Reject traversal after URL decoding, then use the VM's session-aware resolver.
                let decoded = path.removingPercentEncoding ?? path
                guard !decoded.split(separator: "/").contains(".."), !decoded.contains("\\"),
                      let file = await resolveZePath(path) else { throw MediaFavoriteToolError.message("媒体路径无效或文件不存在。") }
                let resource = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                guard resource.isRegularFile == true, let size = resource.fileSize, size > 0,
                      let type = UTType(filenameExtension: file.pathExtension) else { throw MediaFavoriteToolError.message("请选择有效的图片、视频或音频文件。") }
                let kind: FavoriteMediaKind
                if type.conforms(to: .image) {
                    guard CGImageSourceCreateWithURL(file as CFURL, nil) != nil else { throw MediaFavoriteToolError.message("图片格式无效。") }
                    kind = .image
                } else if type.conforms(to: .movie) || type.conforms(to: .audio) {
                    let asset = AVURLAsset(url: file)
                    let mediaType: AVMediaType = type.conforms(to: .movie) ? .video : .audio
                    let tracks = try await asset.loadTracks(withMediaType: mediaType)
                    guard !tracks.isEmpty else { throw MediaFavoriteToolError.message("没有找到可用的音视频轨道。") }
                    kind = mediaType == .video ? .video : .audio
                } else { throw MediaFavoriteToolError.message("收藏夹只接收图片、视频和音频。") }
                try Task.checkCancellation()
                let item = try store.addChecked(fileURL: file, kind: kind, fileName: file.lastPathComponent)
                return favoriteToolJSON(["status": "saved", "favorite": favoriteToolRow(item)])
            case "media_favorite_delete":
                guard let raw = arguments["favorite_id"] as? String, let id = UUID(uuidString: raw),
                      let item = store.items.first(where: { $0.id == id }) else { throw MediaFavoriteToolError.message("找不到收藏 ID，请先调用 media_favorite_list。") }
                guard await RemoteServerAIConfirmationGate.shared.request(serverName: "收藏夹", operation: "删除媒体收藏",
                    detail: "删除收藏：\(item.fileName)\n分类：\(item.kind.title)\n收藏 ID：\(item.id.uuidString)\n仅删除收藏副本，原会话文件保持不变。", isDestructive: true) else {
                    return .init(output: "用户未确认，收藏没有删除。", success: false)
                }
                try Task.checkCancellation()
                try store.removeChecked(item)
                return favoriteToolJSON(["status": "deleted", "favorite_id": id.uuidString, "original_media_unchanged": true])
            default: throw MediaFavoriteToolError.message("未知收藏工具。")
            }
        } catch is CancellationError { return .init(output: "收藏操作已取消。", success: false) }
        catch { return .init(output: "收藏操作失败：\(error.localizedDescription)", success: false) }
    }
    private func favoriteToolRow(_ item: FavoriteMediaItem) -> [String: String] {
        ["favorite_id": item.id.uuidString, "name": item.fileName, "kind": item.kind.rawValue,
         "created_at": ISO8601DateFormatter().string(from: item.createdAt)]
    }
    private func favoriteToolJSON(_ object: [String: Any]) -> MediaFavoriteToolResult {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), let text = String(data: data, encoding: .utf8) else {
            return .init(output: "收藏结果编码失败。", success: false)
        }
        return .init(output: text, success: true)
    }
}
private enum MediaFavoriteToolError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}
