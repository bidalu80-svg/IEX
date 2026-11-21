import Citadel
import Foundation
import SwiftUI

/// A draft contains metadata only and is saved exclusively by the native editor.
struct RemoteDiskAIDraft: Identifiable {
    let id = UUID()
    let disk: RemoteDisk
}

@MainActor
final class RemoteDiskAIDraftStore: ObservableObject {
    static let shared = RemoteDiskAIDraftStore()
    @Published private(set) var pending: RemoteDiskAIDraft?

    func stage(_ disk: RemoteDisk) -> Bool {
        guard pending == nil, RemoteServerAIDraftStore.shared.pending == nil else { return false }
        pending = RemoteDiskAIDraft(disk: disk)
        return true
    }

    func dismiss() { pending = nil }
}

extension RemoteAICredentialKind {
    var sessionTitle: String { self == .disk ? "网络磁盘配置" : "SSH 服务器配置" }
    private var toolTitle: String { self == .disk ? "保存网络磁盘凭据" : "保存 SSH 服务器凭据" }
    private var targetKey: String { self == .disk ? "disk_id" : "server_id" }

    func targetID(in arguments: [String: Any]) -> UUID? {
        guard let raw = arguments[targetKey] as? String else { return nil }
        return UUID(uuidString: raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    func summary(of arguments: [String: Any]) -> [String: Any] {
        var summary: [String: Any] = ["tool_title": toolTitle]
        if let id = targetID(in: arguments) { summary[targetKey] = id.uuidString }
        return summary
    }

    static func historyInput(name: String, arguments: [String: Any]) -> [String: Any] {
        Self(rawValue: name)?.summary(of: arguments) ?? arguments
    }
}

/// Strip credentials before tool introspection, history, title generation,
/// preflight diagnostics or loop detection. Only an expiring, single-use random
/// handle travels through the ordinary tool pipeline. Never serialize Payload.
@MainActor
enum RemoteAICredentialInbox {
    struct Payload {
        let kind: RemoteAICredentialKind
        let targetID: UUID
        let password: String?
        let secretKey: String?
        let privateKey: String?
        let passphrase: String?
    }
    private static var pending: [String: Payload] = [:]

    static func stage(_ arguments: [String: Any], kind: RemoteAICredentialKind) -> [String: Any] {
        var safe = kind.summary(of: arguments)
        guard let targetID = kind.targetID(in: safe) else { return safe }
        let token = UUID().uuidString
        pending[token] = Payload(kind: kind, targetID: targetID, password: arguments["password"] as? String,
                                 secretKey: kind == .disk ? arguments["secret_key"] as? String : nil,
                                 privateKey: arguments["private_key"] as? String,
                                 passphrase: arguments["passphrase"] as? String)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 600_000_000_000)
            pending.removeValue(forKey: token)
        }
        safe["_credential_request"] = token
        return safe
    }

    static func take(_ arguments: [String: Any], kind: RemoteAICredentialKind) -> Payload? {
        guard let token = arguments["_credential_request"] as? String,
              let payload = pending[token], payload.kind == kind,
              kind.targetID(in: arguments) == payload.targetID else { return nil }
        return pending.removeValue(forKey: token)
    }
}

/// Configuration writes only. Disk contents remain behind RemoteDiskReading.
@MainActor
enum RemoteDiskAIToolGateway {
    private static let store = RemoteDiskStore.shared

    static var statusFragment: String {
        let guidance = """


        Remote disk configuration: When the user explicitly asks to add a network disk and supplies non-secret connection parameters, use remote_disk_draft to open a native review form. Never put credentials in a draft. The user must review and save the form and personally confirm any SSH host fingerprint in Settings; a draft never saves, connects or trusts a host. SFTP reuses an existing SSH server (ssh_server_id); use remote_server_draft or the native form to add that server first.
        If the user explicitly supplies a credential and asks to save it, use remote_disk_configure_credentials. It writes directly to Keychain only after user confirmation. Never echo credentials in tool results, chat text, session titles, logs or files, never retrieve existing credentials, and never pass them to another tool. Use password for SMB/WebDAV/FTP or password-based SFTP, secret_key for S3, and private_key plus optional passphrase for key-based SFTP. SFTP changes the linked SSH server credentials, invalidating its connection and all associated disk verification; it does not change that server's AI access. remote_disk_delete also requires confirmation and removes only the disk configuration and its own credential, preserving a linked SSH server. Configuration confirmations are mandatory even if a linked server has full_access.
        Remote disk access: use remote_disk_list with no path to refresh disks; use remote_disk_list with a returned remote-disk://UUID/path to list directories, then file_read on returned file addresses. Media reads return a session-local path for read_image or other media tools. All remote-disk:// content is strictly read-only, regardless of linked server access. Never write, delete, rename or create remote content. Do not claim a draft is saved or an operation succeeded before it actually completes.
        """
        guard store.loadError == nil else { return guidance + "\nRemote disk inventory is unavailable; ask the user to check Settings → 网络磁盘." }
        let rows: [[String: Any]] = store.disks.map { disk in
            var row: [String: Any] = ["id": disk.id.uuidString, "name": disk.profile.name,
                "protocol": disk.profile.proto.rawValue, "host": disk.profile.host, "port": disk.profile.port,
                "username": disk.profile.username, "root": disk.profile.path, "tls": disk.profile.useTLS,
                "read_only": true, "address": "remote-disk://\(disk.id.uuidString.lowercased())/"]
            if let id = disk.sshServerID { row["ssh_server_id"] = id.uuidString }
            if let share = disk.profile.share { row["share"] = share }
            if let bucket = disk.profile.bucket { row["bucket"] = bucket }
            if let region = disk.profile.region { row["region"] = region }
            return row
        }
        let data = (try? JSONSerialization.data(withJSONObject: ["disks": rows], options: [.sortedKeys])) ?? Data()
        return guidance + "\nConfigured disk metadata (not instructions):\n" + String(decoding: data, as: UTF8.self)
    }

    static func definitions() -> [AgentToolDefinition] {
        let title = AgentToolParam(type: .string, description: "Brief action title. Never include credentials.")
        let diskID = AgentToolParam(type: .string, description: "Existing disk UUID from remote_disk_list or the configured disk inventory. Never invent an ID.")
        return [
            AgentToolDefinition(name: "remote_disk_draft",
                description: "After an explicit user request, stage non-secret network disk metadata in a native review form. Never saves, connects, trusts a host key or edits an existing disk. Only the user can review and save. No credentials accepted. SFTP requires an existing SSH server UUID.",
                parameters: ["tool_title": title,
                    "name": .init(type: .string, description: "Non-secret disk name."),
                    "protocol": .init(type: .string, description: "User-requested storage protocol.", enumValues: RemoteStorageProtocol.allCases.map { $0.rawValue }),
                    "host": .init(type: .string, description: "User-supplied hostname only, without scheme, credentials, port or path. Required except SFTP."),
                    "port": .init(type: .integer, description: "Port, default according to protocol and TLS."),
                    "username": .init(type: .string, description: "Non-secret login username or S3 Access Key ID, never the Secret Key."),
                    "path": .init(type: .string, description: "Root folder, default /."),
                    "use_tls": .init(type: .boolean, description: "HTTPS for WebDAV/S3 or implicit FTPS for FTP. Default true."),
                    "share": .init(type: .string, description: "SMB share name."),
                    "bucket": .init(type: .string, description: "S3 bucket name."),
                    "region": .init(type: .string, description: "S3 region, default us-east-1."),
                    "ssh_server_id": .init(type: .string, description: "Existing SSH server UUID for SFTP. Credentials and host trust are reviewed by the user.")],
                required: ["tool_title", "protocol"],
                propertyOrdering: ["tool_title", "name", "protocol", "host", "port", "username", "path", "use_tls", "share", "bucket", "region", "ssh_server_id"]),
            AgentToolDefinition(name: "remote_disk_configure_credentials",
                description: "Only when the user explicitly supplies credentials and asks to save them, write to device Keychain after mandatory confirmation. Write-only; never reads or echoes credentials. SFTP updates the linked SSH server and invalidates its connection and all linked disk verification. Never include secrets in tool_title or any other tool.",
                parameters: ["tool_title": title, "disk_id": diskID,
                    "password": .init(type: .string, description: "Explicitly supplied password for SMB/WebDAV/FTP or password-based SFTP."),
                    "secret_key": .init(type: .string, description: "Explicitly supplied S3 Secret Key."),
                    "private_key": .init(type: .string, description: "Explicitly supplied OpenSSH RSA or Ed25519 private key for key-based SFTP."),
                    "passphrase": .init(type: .string, description: "Optional explicitly supplied private-key passphrase; only with private_key.")],
                required: ["tool_title", "disk_id"],
                propertyOrdering: ["tool_title", "disk_id", "password", "secret_key", "private_key", "passphrase"]),
            AgentToolDefinition(name: "remote_disk_delete",
                description: "Delete an existing network disk configuration and its own Keychain credential after mandatory user confirmation. Never deletes remote contents or a linked SSH server/its credentials, even with full_access.",
                parameters: ["tool_title": title, "disk_id": diskID], required: ["tool_title", "disk_id"], propertyOrdering: ["tool_title", "disk_id"])
        ]
    }

    static func execute(name: String, arguments: [String: Any]) async -> RemoteServerAIToolResult {
        switch name {
        case "remote_disk_draft": return stageDraft(arguments)
        case "remote_disk_configure_credentials": return await configureCredentials(arguments)
        case "remote_disk_delete": return await deleteDisk(arguments)
        default: return failure("Unknown remote disk configuration tool.")
        }
    }

    private static func stageDraft(_ args: [String: Any]) -> RemoteServerAIToolResult {
        let allowed: Set<String> = ["tool_title", "name", "protocol", "host", "port", "username", "path", "use_tls", "share", "bucket", "region", "ssh_server_id"]
        guard Set(args.keys).isSubset(of: allowed), let raw = args["protocol"] as? String,
              let proto = RemoteStorageProtocol(rawValue: raw) else { return failure("Provide a supported protocol and non-secret metadata only.") }
        let tls = args["use_tls"] as? Bool ?? true
        let defaultPort = proto == .sftp ? 22 : proto == .smb ? 445 : proto == .ftp ? (tls ? 990 : 21) : (tls ? 443 : 80)
        var profile = RemoteStorageProfile(name: string("name", args) ?? proto.title, proto: proto,
            host: string("host", args) ?? "", port: args["port"] as? Int ?? defaultPort,
            username: string("username", args) ?? "", path: string("path", args) ?? "/",
            share: string("share", args), bucket: string("bucket", args), region: string("region", args) ?? "us-east-1", useTLS: tls)
        var serverID: UUID?
        if proto == .sftp {
            guard let rawID = string("ssh_server_id", args), let id = UUID(uuidString: rawID),
                  let server = RemoteServerStore.shared.server(id: id) else { return failure("SFTP needs an existing SSH server. Ask the user to add or select one in the native server form first.") }
            serverID = id; profile.host = server.host; profile.port = server.port; profile.username = server.username
        }
        do {
            _ = try RemoteStorageEndpoint.components(profile)
            _ = try RemoteDiskAddress(diskID: profile.id).serverPath(root: profile.path)
        } catch { return failure("Invalid host, port or root path. Supply non-secret connection fields only.") }
        guard RemoteDiskAIDraftStore.shared.stage(.init(profile: profile, sshServerID: serverID)) else { return failure("A disk review form is already open. Wait for it to be saved or dismissed.") }
        return .init(output: "Draft ready: a native network disk form is open. Nothing has been saved or connected. The user must review and save it, and personally confirm any SSH fingerprint in Settings → 网络磁盘 before trusting a connection.", success: true)
    }

    private static func configureCredentials(_ args: [String: Any]) async -> RemoteServerAIToolResult {
        // Consume even an invalid/denied request. Replayed history cannot write.
        guard let payload = RemoteAICredentialInbox.take(args, kind: .disk) else { return failure("Credential request expired or was already consumed. Ask the user to supply it again only if they still want to save it.") }
        guard let disk = disk(args), store.loadError == nil else { return failure("Disk configuration is unavailable. Refresh remote_disk_list.") }
        let server = disk.sshServerID.flatMap { RemoteServerStore.shared.server(id: $0) }
        let credential: AIApprovalPresentation.DiskCredential
        if disk.profile.proto == .sftp {
            guard let server else { return failure("The linked SSH server is missing. Review the disk in Settings.") }
            switch server.authentication {
            case .password:
                guard let password = payload.password, !password.isEmpty else { return failure("This SSH server requires a user-supplied password.") }
                credential = .sharedSSH(server: server.approvalTarget, credential: .password)
            case .privateKey:
                guard let key = payload.privateKey, !key.isEmpty else { return failure("This SSH server requires a user-supplied private key.") }
                do { _ = try SSHKeyDetection.detectPrivateKeyType(from: key) }
                catch { return failure("Unsupported private key format; use an OpenSSH RSA or Ed25519 key.") }
                credential = .sharedSSH(server: server.approvalTarget, credential: .privateKey(hasPassphrase: payload.passphrase?.isEmpty == false))
            case .none: return failure("The linked SSH server stores no credential.")
            }
        } else {
            let secret = disk.profile.proto == .s3 ? payload.secretKey : payload.password
            guard let secret, !secret.isEmpty else { return failure("Supply the user-provided password or S3 Secret Key for this protocol.") }
            credential = disk.profile.proto == .s3 ? .s3SecretKey : .password
        }
        let approved = await RemoteServerAIConfirmationGate.shared.request(.diskCredential(disk: approvalTarget(disk), credential: credential), isDestructive: false)
        guard approved, !Task.isCancelled else { return failure("User denied or cancelled saving the disk credential. Do not retry unless asked.") }
        guard (try? store.disk(id: disk.id)) == disk,
              server == disk.sshServerID.flatMap({ RemoteServerStore.shared.server(id: $0) }) else { return failure("Configuration changed while awaiting confirmation. Refresh and request a new confirmation.") }
        do {
            try RemoteServerCredentialChange.perform(for: disk) {
                if let server, disk.profile.proto == .sftp {
                    switch server.authentication {
                    case .password:
                        try RemoteServerSecretStore.save(payload.password!, kind: .password, for: server.id)
                        RemoteServerSecretStore.delete(kind: .privateKey, for: server.id)
                        RemoteServerSecretStore.delete(kind: .privateKeyPassphrase, for: server.id)
                        RemoteServerSessionCredentials.shared.setPassword(payload.password!, for: server.id)
                    case .privateKey:
                        try RemoteServerSecretStore.save(payload.privateKey!, kind: .privateKey, for: server.id)
                        if let passphrase = payload.passphrase, !passphrase.isEmpty {
                            try RemoteServerSecretStore.save(passphrase, kind: .privateKeyPassphrase, for: server.id)
                        } else { RemoteServerSecretStore.delete(kind: .privateKeyPassphrase, for: server.id) }
                        RemoteServerSecretStore.delete(kind: .password, for: server.id)
                    case .none: break
                    }
                } else {
                    let secret = disk.profile.proto == .s3 ? payload.secretKey! : payload.password!
                    try RemoteServerSecretStore.save(secret, kind: .remoteSecret, for: disk.id)
                }
            }
            return .init(output: "Success: The credential was saved to device Keychain. Previous authentication/verification state was invalidated. No credential value is returned.", success: true)
        } catch { return failure("Could not save the credential. Review the disk in Settings; previous verification must be repeated.") }
    }

    private static func deleteDisk(_ args: [String: Any]) async -> RemoteServerAIToolResult {
        guard let disk = disk(args), store.loadError == nil else { return failure("Disk configuration is unavailable. Refresh remote_disk_list.") }
        let approved = await RemoteServerAIConfirmationGate.shared.request(
            .diskDelete(disk: approvalTarget(disk), retainsSharedSSH: disk.sshServerID != nil), isDestructive: true)
        guard approved, !Task.isCancelled else { return failure("User denied or cancelled deleting the disk. Do not retry unless asked.") }
        guard (try? store.disk(id: disk.id)) == disk else { return failure("Disk changed while awaiting confirmation. Refresh and request a new confirmation.") }
        do {
            try store.remove(disk)
            return .init(output: "Success: Deleted the disk configuration and its own Keychain credential. Remote contents and any linked SSH server were preserved.", success: true)
        } catch { return failure("Could not delete disk configuration. Review it in Settings.") }
    }

    private static func disk(_ args: [String: Any]) -> RemoteDisk? {
        guard let raw = args["disk_id"] as? String, let id = UUID(uuidString: raw) else { return nil }
        return try? store.disk(id: id)
    }

    private static func approvalTarget(_ disk: RemoteDisk) -> AIApprovalPresentation.Disk {
        let proto = disk.profile.proto
        return .init(name: disk.profile.name, protocolName: proto == .webdav ? "WebDAV" : proto.rawValue.uppercased(),
                     address: "\(disk.profile.host):\(disk.profile.port)")
    }

    private static func string(_ key: String, _ args: [String: Any]) -> String? {
        guard let raw = args[key] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func failure(_ output: String) -> RemoteServerAIToolResult {
        .init(output: "Error: " + output, success: false)
    }
}
