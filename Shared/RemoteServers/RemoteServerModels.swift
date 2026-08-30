import Foundation

/// Independent network storage protocols used by backup destinations. These
/// profiles describe connection metadata only; passwords and access keys are
/// stored in the Keychain under the profile ID.
enum RemoteStorageProtocol: String, Codable, CaseIterable, Identifiable, Hashable, Sendable {
    case smb
    case webdav
    case sftp
    case s3
    case ftp

    var id: String { rawValue }

    var title: String {
        switch self {
        case .smb: return "SMB / Windows 共享"
        case .webdav: return "WebDAV"
        case .sftp: return "SFTP"
        case .s3: return "S3 兼容存储"
        case .ftp: return "FTP"
        }
    }
}

/// Persisted connection metadata for a Ze-owned network storage destination.
/// `secretKey` identifies a Keychain item; credentials never enter Codable
/// backups or UserDefaults.
struct RemoteStorageProfile: Codable, Identifiable, Hashable, Sendable {
    var id: UUID
    var name: String
    var proto: RemoteStorageProtocol
    var host: String
    var port: Int
    var username: String
    var path: String
    var share: String?
    var bucket: String?
    var region: String?
    var useTLS: Bool
    var secretKey: String

    init(
        id: UUID = UUID(), name: String, proto: RemoteStorageProtocol,
        host: String, port: Int, username: String = "", path: String = "/",
        share: String? = nil, bucket: String? = nil, region: String? = nil,
        useTLS: Bool = true, secretKey: String = ""
    ) {
        self.id = id; self.name = name; self.proto = proto; self.host = host
        self.port = port; self.username = username; self.path = path
        self.share = share; self.bucket = bucket; self.region = region
        self.useTLS = useTLS; self.secretKey = secretKey
    }
}

/// Common contract consumed by backup/restore. Implementations are protocol
/// clients owned by Ze (WebDAV, S3, FTP, SMB2, or the existing SFTP bridge),
/// so the backup engine never needs to know wire-level details.
protocol RemoteStorageClient: Sendable {
    func testConnection() async throws
    func list(path: String) async throws -> [RemoteSFTPEntry]
    func upload(data: Data, to path: String) async throws
    func download(path: String) async throws -> Data
}

/// A user-owned SSH endpoint. Secrets deliberately do not live in this model:
/// the profile can be backed up or synced without exporting a private key,
/// passphrase, or password.
struct RemoteServerProfile: Codable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var host: String
    var port: Int
    var username: String
    var labels: [String]
    var note: String
    var authentication: RemoteServerAuthentication
    var enabled: Bool
    var aiAccess: RemoteServerAIAccessLevel
    var quickCommands: [RemoteServerQuickCommand]
    var knownHost: RemoteKnownHost?
    var createdAt: Date
    var updatedAt: Date
    var lastConnectedAt: Date?

    init(
        id: UUID = UUID(),
        name: String,
        host: String,
        port: Int = 22,
        username: String,
        labels: [String] = [],
        note: String = "",
        authentication: RemoteServerAuthentication = .privateKey,
        enabled: Bool = true,
        aiAccess: RemoteServerAIAccessLevel = .none,
        quickCommands: [RemoteServerQuickCommand] = [],
        knownHost: RemoteKnownHost? = nil,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        lastConnectedAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.host = host
        self.port = port
        self.username = username
        self.labels = labels
        self.note = note
        self.authentication = authentication
        self.enabled = enabled
        self.aiAccess = aiAccess
        self.quickCommands = quickCommands
        self.knownHost = knownHost
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastConnectedAt = lastConnectedAt
    }

    var endpointDescription: String {
        "\(username)@\(host):\(port)"
    }

    var normalizedHost: String {
        host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    var hasTrustedHostKey: Bool {
        knownHost?.fingerprint.isEmpty == false
    }
}

enum RemoteServerAuthentication: String, Codable, CaseIterable, Identifiable {
    case privateKey
    case password

    var id: String { rawValue }

    var title: String {
        switch self {
        case .privateKey: return "私钥"
        case .password: return "密码（仅本次连接）"
        }
    }
}

/// The AI never receives credentials. This value only decides which operation
/// requests may be proposed, and write/command operations still require a
/// user confirmation at execution time.
enum RemoteServerAIAccessLevel: String, Codable, CaseIterable, Identifiable {
    case none
    case readOnly
    case commandsWithConfirmation
    case fullWithConfirmation

    var id: String { rawValue }

    var title: String {
        switch self {
        case .none: return "不允许 AI 访问"
        case .readOnly: return "仅允许读取"
        case .commandsWithConfirmation: return "允许执行命令（每次确认）"
        case .fullWithConfirmation: return "允许读写与命令（每次确认）"
        }
    }

    var allowsRead: Bool { self != .none }
    var allowsCommands: Bool { self == .commandsWithConfirmation || self == .fullWithConfirmation }
    var allowsWrites: Bool { self == .fullWithConfirmation }
}

struct RemoteServerQuickCommand: Codable, Identifiable, Hashable {
    var id: UUID
    var title: String
    var command: String
    var requiresConfirmation: Bool

    init(id: UUID = UUID(), title: String, command: String, requiresConfirmation: Bool = true) {
        self.id = id
        self.title = title
        self.command = command
        self.requiresConfirmation = requiresConfirmation
    }

    static let defaults: [RemoteServerQuickCommand] = [
        .init(title: "系统状态", command: "uptime && uname -a", requiresConfirmation: false),
        .init(title: "磁盘空间", command: "df -h", requiresConfirmation: false),
        .init(title: "内存使用", command: "free -h || vm_stat", requiresConfirmation: false),
    ]
}

/// A SHA-256 fingerprint from the SSH server's public host key. It is public
/// identity metadata, never an authentication secret.
struct RemoteKnownHost: Codable, Hashable {
    var algorithm: String
    var fingerprint: String
    var verifiedAt: Date

    init(algorithm: String, fingerprint: String, verifiedAt: Date = .now) {
        self.algorithm = algorithm
        self.fingerprint = fingerprint
        self.verifiedAt = verifiedAt
    }
}

enum RemoteServerConnectionPhase: String, Codable {
    case idle
    case resolving
    case connecting
    case verifyingHost
    case authenticating
    case ready
    case failed
}

struct RemoteServerConnectionDiagnostic: Identifiable, Hashable {
    let id = UUID()
    let phase: RemoteServerConnectionPhase
    let title: String
    let detail: String
    let occurredAt: Date

    init(phase: RemoteServerConnectionPhase, title: String, detail: String = "", occurredAt: Date = .now) {
        self.phase = phase
        self.title = title
        self.detail = detail
        self.occurredAt = occurredAt
    }
}

/// Public metadata returned by an SFTP directory listing. This deliberately
/// contains no file content, local bookmark, or credential information.
struct RemoteSFTPEntry: Identifiable, Hashable, Sendable {
    var path: String
    var name: String
    var isDirectory: Bool
    var size: UInt64?
    var modifiedAt: Date?
    var permissions: UInt32?

    var id: String { path }
}

enum RemoteServerError: LocalizedError, Equatable {
    case invalidProfile(String)
    case secretMissing
    case hostKeyUntrusted(RemoteKnownHost)
    case hostKeyChanged(expected: RemoteKnownHost, received: RemoteKnownHost)
    case unsupportedPrivateKey
    case authenticationFailed
    case connectionFailed(String)
    case operationNotPermitted

    var errorDescription: String? {
        switch self {
        case .invalidProfile(let detail): return "服务器配置无效：\(detail)"
        case .secretMissing: return "未找到此服务器所需的私钥或本次连接密码"
        case .hostKeyUntrusted: return "此服务器的主机指纹尚未确认"
        case .hostKeyChanged: return "服务器主机指纹已变化，连接已被阻止"
        case .unsupportedPrivateKey: return "暂不支持此私钥格式"
        case .authenticationFailed: return "SSH 认证失败"
        case .connectionFailed(let detail): return "连接失败：\(detail)"
        case .operationNotPermitted: return "当前服务器权限不允许此操作"
        }
    }
}
