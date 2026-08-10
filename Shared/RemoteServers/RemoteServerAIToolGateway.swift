import Foundation

/// Result returned to the model after a remote-server tool request. The
/// gateway never serializes local authentication material into this value.
struct RemoteServerAIToolResult {
    let output: String
    let success: Bool
}

/// A single explicit user-approval request for a model-proposed remote action.
/// Read-only operations do not reach this gate; commands and all mutations do.
struct RemoteServerAIConfirmationRequest: Identifiable {
    let id = UUID()
    let serverName: String
    let operation: String
    let detail: String
    let isDestructive: Bool
}

/// Non-secret connection details proposed by a model. A draft is never
/// persisted or connected automatically: the native editor remains the only
/// place where a user can enter credentials and save a server profile.
struct RemoteServerAIDraft: Identifiable, Hashable {
    let id = UUID()
    let name: String
    let host: String
    let port: Int
    let username: String
    let labels: [String]
    let note: String
    let authentication: RemoteServerAuthentication
    let aiAccess: RemoteServerAIAccessLevel
}

@MainActor
final class RemoteServerAIDraftStore: ObservableObject {
    static let shared = RemoteServerAIDraftStore()

    @Published private(set) var pending: RemoteServerAIDraft?

    private init() {}

    func stage(_ draft: RemoteServerAIDraft) -> Bool {
        guard pending == nil else { return false }
        pending = draft
        return true
    }

    func dismiss() {
        pending = nil
    }
}

@MainActor
final class RemoteServerAIConfirmationGate: ObservableObject {
    static let shared = RemoteServerAIConfirmationGate()

    @Published private(set) var pending: RemoteServerAIConfirmationRequest?
    private var continuation: CheckedContinuation<Bool, Never>?

    private init() {}

    func request(
        serverName: String,
        operation: String,
        detail: String,
        isDestructive: Bool
    ) async -> Bool {
        guard pending == nil else { return false }
        return await withCheckedContinuation { continuation in
            self.continuation = continuation
            self.pending = RemoteServerAIConfirmationRequest(
                serverName: serverName,
                operation: operation,
                detail: detail,
                isDestructive: isDestructive
            )
        }
    }

    func resolve(allowed: Bool) {
        let continuation = self.continuation
        self.continuation = nil
        self.pending = nil
        continuation?.resume(returning: allowed)
    }
}

/// The only route through which a model may inspect or operate a configured
/// server. It exposes profile metadata and approved results, never private
/// keys, passphrases, passwords, Keychain records, or raw connection internals.
@MainActor
enum RemoteServerAIToolGateway {
    private static let store = RemoteServerStore.shared
    private static let connection = RemoteSSHConnectionService.shared

    static var hasVisibleServers: Bool {
        !authorizedServers.isEmpty
    }

    static var statusFragment: String {
        let servers = authorizedServers
        let configurationGuidance = "\n\nRemote server configuration: When the user explicitly asks to add an SSH server and has supplied its host and username, use remote_server_draft to prepare a native review form. Pass only non-secret metadata. Never pass, request through this tool, infer, print, or store passwords, private keys, passphrases, Keychain values, or host-key approvals. The user must review the form, enter credentials locally, save it, and confirm the SSH host fingerprint themselves."
        guard !servers.isEmpty else {
            return configurationGuidance + "\n\nRemote server access: no server is currently authorized for AI. Do not claim that you can operate a user's SSH server."
        }
        let descriptions = servers.map { server in
            "- \(server.name) [id: \(server.id.uuidString), endpoint: \(server.endpointDescription), connected: \(connection.isConnected(to: server.id)), access: \(server.aiAccess.title)]"
        }.joined(separator: "\n")
        return configurationGuidance + "\n\nRemote server access: Use remote_server_list to refresh the current state before operating a server. The following server metadata is authorized for this model session:\n\(descriptions)\nUse only the remote_server_* tools. Never request, infer, print, or attempt to retrieve passwords, private keys, passphrases, or Keychain data. A server must already be connected by the user in Settings. Every command and every write/delete/rename operation opens a user confirmation; never describe an action as completed before the tool returns success."
    }

    static func definitions() -> [AgentToolDefinition] {
        var tools = [AgentToolDefinition(
            name: "remote_server_draft",
            description: "Prepare a native SSH server review form after the user explicitly asks to add a server. This only stages non-secret metadata and never saves, connects, trusts a host key, or changes an existing server. Do not call until the user has provided both host and username. Never include passwords, private keys, passphrases, tokens, or Keychain data.",
            parameters: [
                "tool_title": AgentToolParam(type: .string, description: "Brief user-visible action title in the user's language."),
                "name": AgentToolParam(type: .string, description: "Human-readable server name. Use a clear name derived from the user's description."),
                "host": AgentToolParam(type: .string, description: "SSH host name or IP address only, without ssh://, username, path, password, or port."),
                "port": AgentToolParam(type: .integer, description: "SSH port. Defaults to 22 when omitted."),
                "username": AgentToolParam(type: .string, description: "SSH login username, supplied by the user."),
                "authentication": AgentToolParam(type: .string, description: "Preferred native credential entry mode. This is not a credential.", enumValues: ["private_key", "password"]),
                "labels": AgentToolParam(type: .string, description: "Optional comma-separated non-secret labels."),
                "note": AgentToolParam(type: .string, description: "Optional non-secret note for the user."),
                "ai_access": AgentToolParam(type: .string, description: "Suggested AI access only. The native form requires user review before save.", enumValues: ["none", "read_only", "commands_with_confirmation", "full_with_confirmation"]),
            ],
            required: ["tool_title", "host", "username"],
            propertyOrdering: ["tool_title", "name", "host", "port", "username", "authentication", "labels", "note", "ai_access"]
        )]

        guard hasVisibleServers else { return tools }
        let serverIDs = authorizedServers.map { $0.id.uuidString }
        let commonServer = AgentToolParam(
            type: .string,
            description: "Server UUID returned by remote_server_list. Never invent an ID.",
            enumValues: serverIDs
        )
        tools += [
            AgentToolDefinition(
                name: "remote_server_list",
                description: "List AI-authorized SSH server metadata and connection state. This reveals no password, private key, passphrase, or Keychain content.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Brief user-visible action title in the user's language."),
                ],
                required: ["tool_title"],
                propertyOrdering: ["tool_title"]
            ),
            AgentToolDefinition(
                name: "remote_server_command",
                description: "Run one shell command on a user-connected remote SSH server. Available only when the server allows AI commands. Every request requires a user confirmation before execution.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Brief user-visible action title in the user's language."),
                    "server_id": commonServer,
                    "command": AgentToolParam(type: .string, description: "The exact remote shell command to propose. Keep it focused and do not include credentials."),
                ],
                required: ["tool_title", "server_id", "command"],
                propertyOrdering: ["tool_title", "server_id", "command"]
            ),
            AgentToolDefinition(
                name: "remote_sftp_list",
                description: "List a directory through SFTP on a user-connected, AI-authorized remote server. Read-only operation.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Brief user-visible action title in the user's language."),
                    "server_id": commonServer,
                    "path": AgentToolParam(type: .string, description: "Remote absolute or SFTP-resolvable directory path."),
                ],
                required: ["tool_title", "server_id", "path"],
                propertyOrdering: ["tool_title", "server_id", "path"]
            ),
            AgentToolDefinition(
                name: "remote_sftp_read",
                description: "Read a UTF-8 text file through SFTP on a user-connected, AI-authorized remote server. Binary data is not returned to the model.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Brief user-visible action title in the user's language."),
                    "server_id": commonServer,
                    "path": AgentToolParam(type: .string, description: "Remote file path to read."),
                ],
                required: ["tool_title", "server_id", "path"],
                propertyOrdering: ["tool_title", "server_id", "path"]
            ),
            AgentToolDefinition(
                name: "remote_sftp_write",
                description: "Make a SFTP mutation on a user-connected remote server: write a UTF-8 text file, create a directory, rename, or delete. Available only when the server allows AI writes. Every request requires user confirmation.",
                parameters: [
                    "tool_title": AgentToolParam(type: .string, description: "Brief user-visible action title in the user's language."),
                    "server_id": commonServer,
                    "action": AgentToolParam(type: .string, description: "Mutation to perform.", enumValues: ["write", "mkdir", "rename", "delete"]),
                    "path": AgentToolParam(type: .string, description: "Target remote path."),
                    "content": AgentToolParam(type: .string, description: "UTF-8 content for action=write. Required only for write."),
                    "new_path": AgentToolParam(type: .string, description: "New remote path for action=rename. Required only for rename."),
                    "is_directory": AgentToolParam(type: .boolean, description: "For action=delete, true only for an empty directory; otherwise false."),
                ],
                required: ["tool_title", "server_id", "action", "path"],
                propertyOrdering: ["tool_title", "server_id", "action", "path", "new_path", "content", "is_directory"]
            ),
        ]
        return tools
    }

    static func execute(name: String, arguments: [String: Any]) async -> RemoteServerAIToolResult {
        switch name {
        case "remote_server_draft":
            return stageDraft(arguments)
        case "remote_server_list":
            return .init(output: listOutput(), success: true)
        case "remote_server_command":
            return await runCommand(arguments)
        case "remote_sftp_list":
            return await listDirectory(arguments)
        case "remote_sftp_read":
            return await readFile(arguments)
        case "remote_sftp_write":
            return await mutateFileSystem(arguments)
        default:
            return .init(output: "Error: Unknown remote server tool '\(name)'.", success: false)
        }
    }

    private static func stageDraft(_ arguments: [String: Any]) -> RemoteServerAIToolResult {
        guard let host = normalizedHost(from: arguments), let username = string("username", from: arguments) else {
            return .init(output: "Error: A host and username are required before Ze can prepare a server configuration form.", success: false)
        }

        let port = integer("port", from: arguments) ?? 22
        guard (1...65_535).contains(port) else {
            return .init(output: "Error: SSH port must be between 1 and 65535.", success: false)
        }

        let name = string("name", from: arguments) ?? (username + "@" + host)
        let draft = RemoteServerAIDraft(
            name: name,
            host: host,
            port: port,
            username: username,
            labels: string("labels", from: arguments)?.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty } ?? [],
            note: string("note", from: arguments) ?? "",
            authentication: authentication(from: arguments),
            aiAccess: accessLevel(from: arguments)
        )
        guard RemoteServerAIDraftStore.shared.stage(draft) else {
            return .init(output: "Error: A server configuration review is already open. Wait for the user to save or dismiss it before preparing another draft.", success: false)
        }
        return .init(output: "Draft ready. Ze opened a native server review form for \(draft.username)@\(draft.host):\(draft.port). The user must verify every field, enter credentials locally, save the profile, and confirm the SSH host fingerprint before any connection can be trusted.", success: true)
    }

    private static var authorizedServers: [RemoteServerProfile] {
        store.servers.filter { $0.enabled && $0.aiAccess != .none }
    }

    private static func listOutput() -> String {
        let rows: [[String: Any]] = authorizedServers.map { server in
            [
                "id": server.id.uuidString,
                "name": server.name,
                "endpoint": server.endpointDescription,
                "labels": server.labels,
                "connected": connection.isConnected(to: server.id),
                "access": server.aiAccess.title,
                "can_read": server.aiAccess.allowsRead,
                "can_run_commands": server.aiAccess.allowsCommands,
                "can_write": server.aiAccess.allowsWrites,
            ]
        }
        return json(["servers": rows, "security": "Credentials are intentionally unavailable to AI."])
    }

    private static func runCommand(_ arguments: [String: Any]) async -> RemoteServerAIToolResult {
        guard let server = server(from: arguments, required: .commands) else {
            return denied(arguments, required: "执行命令")
        }
        guard connection.isConnected(to: server.id) else {
            return .init(output: "Error: Server '\(server.name)' is not connected. Ask the user to connect it from Settings → 服务器与连接 first.", success: false)
        }
        guard let command = string("command", from: arguments) else {
            return .init(output: "Error: Missing command.", success: false)
        }
        let approved = await RemoteServerAIConfirmationGate.shared.request(
            serverName: server.name,
            operation: "执行远程命令",
            detail: command,
            isDestructive: true
        )
        guard approved else { return .init(output: "User denied the remote command. Do not retry unless the user asks again.", success: false) }
        do {
            let output = try await connection.executeCommand(command, on: server.id)
            return .init(output: truncate(output), success: true)
        } catch {
            return .init(output: "Error: \(error.localizedDescription)", success: false)
        }
    }

    private static func listDirectory(_ arguments: [String: Any]) async -> RemoteServerAIToolResult {
        guard let server = server(from: arguments, required: .read) else { return denied(arguments, required: "读取文件") }
        guard connection.isConnected(to: server.id) else { return notConnected(server) }
        guard let path = string("path", from: arguments) else { return .init(output: "Error: Missing path.", success: false) }
        do {
            let directoryEntries = try await connection.listDirectory(at: path, on: server.id)
            let entries = directoryEntries.prefix(200).map { entry in
                var item: [String: Any] = ["name": entry.name, "path": entry.path, "directory": entry.isDirectory]
                if let size = entry.size { item["size"] = size }
                return item
            }
            return .init(output: json(["path": path, "entries": entries]), success: true)
        } catch {
            return .init(output: "Error: \(error.localizedDescription)", success: false)
        }
    }

    private static func readFile(_ arguments: [String: Any]) async -> RemoteServerAIToolResult {
        guard let server = server(from: arguments, required: .read) else { return denied(arguments, required: "读取文件") }
        guard connection.isConnected(to: server.id) else { return notConnected(server) }
        guard let path = string("path", from: arguments) else { return .init(output: "Error: Missing path.", success: false) }
        do {
            let data = try await connection.downloadFile(at: path, on: server.id, maximumBytes: 512 * 1_024)
            guard let text = String(data: data, encoding: .utf8) else {
                return .init(output: "Error: The remote file is not UTF-8 text and was not exposed to the model.", success: false)
            }
            return .init(output: truncate(text), success: true)
        } catch {
            return .init(output: "Error: \(error.localizedDescription)", success: false)
        }
    }

    private static func mutateFileSystem(_ arguments: [String: Any]) async -> RemoteServerAIToolResult {
        guard let server = server(from: arguments, required: .write) else { return denied(arguments, required: "写入文件") }
        guard connection.isConnected(to: server.id) else { return notConnected(server) }
        guard let action = string("action", from: arguments), let path = string("path", from: arguments) else {
            return .init(output: "Error: Missing action or path.", success: false)
        }

        let detail: String
        switch action {
        case "write": detail = "写入文件：\(path)"
        case "mkdir": detail = "新建文件夹：\(path)"
        case "rename": detail = "重命名：\(path) → \(string("new_path", from: arguments) ?? "")"
        case "delete": detail = "删除：\(path)"
        default: return .init(output: "Error: Unsupported SFTP mutation '\(action)'.", success: false)
        }
        let approved = await RemoteServerAIConfirmationGate.shared.request(
            serverName: server.name,
            operation: "修改远程文件",
            detail: detail,
            isDestructive: action == "delete" || action == "write"
        )
        guard approved else { return .init(output: "User denied the remote file operation. Do not retry unless the user asks again.", success: false) }

        do {
            switch action {
            case "write":
                guard let content = arguments["content"] as? String else { return .init(output: "Error: Missing content for write.", success: false) }
                try await connection.uploadFile(Data(content.utf8), to: path, on: server.id, maximumBytes: 1_024 * 1_024)
            case "mkdir":
                try await connection.createDirectory(at: path, on: server.id)
            case "rename":
                guard let newPath = string("new_path", from: arguments) else { return .init(output: "Error: Missing new_path for rename.", success: false) }
                try await connection.renameItem(at: path, to: newPath, on: server.id)
            case "delete":
                try await connection.deleteItem(at: path, isDirectory: arguments["is_directory"] as? Bool ?? false, on: server.id)
            default: break
            }
            return .init(output: "Success: \(detail)", success: true)
        } catch {
            return .init(output: "Error: \(error.localizedDescription)", success: false)
        }
    }

    private enum RequiredAccess { case read, commands, write }

    private static func server(from arguments: [String: Any], required: RequiredAccess) -> RemoteServerProfile? {
        guard let value = string("server_id", from: arguments), let id = UUID(uuidString: value),
              let server = store.server(id: id), server.enabled else { return nil }
        switch required {
        case .read: return server.aiAccess.allowsRead ? server : nil
        case .commands: return server.aiAccess.allowsCommands ? server : nil
        case .write: return server.aiAccess.allowsWrites ? server : nil
        }
    }

    private static func denied(_ arguments: [String: Any], required: String) -> RemoteServerAIToolResult {
        let supplied = string("server_id", from: arguments) ?? "unknown"
        return .init(output: "Error: Server '\(supplied)' is not authorized for AI to \(required). Ask the user to change that server's AI access in Settings → 服务器与连接.", success: false)
    }

    private static func notConnected(_ server: RemoteServerProfile) -> RemoteServerAIToolResult {
        .init(output: "Error: Server '\(server.name)' is not connected. Ask the user to connect it from Settings → 服务器与连接 first.", success: false)
    }

    private static func string(_ name: String, from arguments: [String: Any]) -> String? {
        guard let value = arguments[name] as? String else { return nil }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func integer(_ name: String, from arguments: [String: Any]) -> Int? {
        if let value = arguments[name] as? Int { return value }
        if let value = arguments[name] as? NSNumber { return value.intValue }
        if let value = arguments[name] as? String { return Int(value) }
        return nil
    }

    private static func normalizedHost(from arguments: [String: Any]) -> String? {
        guard let host = string("host", from: arguments) else { return nil }
        guard !host.contains(where: { $0.isWhitespace }),
              !host.contains("/"),
              !host.contains("@"),
              !host.contains("://") else { return nil }
        return host
    }

    private static func authentication(from arguments: [String: Any]) -> RemoteServerAuthentication {
        string("authentication", from: arguments) == "password" ? .password : .privateKey
    }

    private static func accessLevel(from arguments: [String: Any]) -> RemoteServerAIAccessLevel {
        switch string("ai_access", from: arguments) {
        case "read_only": return .readOnly
        case "commands_with_confirmation": return .commandsWithConfirmation
        case "full_with_confirmation": return .fullWithConfirmation
        default: return .none
        }
    }

    private static func truncate(_ text: String, maximum: Int = 15_000) -> String {
        guard text.count > maximum else { return text }
        return String(text.prefix(maximum)) + "\n[output truncated]"
    }

    private static func json(_ object: Any) -> String {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{\"error\":\"Unable to encode result\"}"
        }
        return text
    }
}
