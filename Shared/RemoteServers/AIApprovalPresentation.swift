import Foundation

enum AIApprovalPresentation: Equatable, Sendable {
    struct Repository: Equatable, Sendable {
        let account: String
        let owner: String
        let name: String

        var fullName: String { "\(owner)/\(name)" }
    }

    enum FileChange: Equatable, Sendable {
        case write(path: String, content: String)
        case delete(path: String)
    }

    struct Server: Equatable, Sendable {
        let name: String
        let address: String
        let user: String
    }

    struct Disk: Equatable, Sendable {
        let name: String
        let protocolName: String
        let address: String
    }

    enum SFTPChange: Equatable, Sendable {
        case write(path: String, content: String)
        case mkdir(path: String)
        case rename(path: String, to: String)
        case delete(path: String, isDirectory: Bool)
    }

    enum SSHCredential: Equatable, Sendable {
        case password
        case privateKey(hasPassphrase: Bool)
    }

    enum DiskCredential: Equatable, Sendable {
        case password
        case s3SecretKey
        case sharedSSH(server: Server, credential: SSHCredential)
    }

    enum FavoriteKind: Equatable, Sendable { case image, video, audio }

    enum SubagentModel: Equatable, Sendable {
        case followConversation
        case model(name: String, provider: String)
    }

    case githubCommit(repository: Repository, branch: String, expectedHead: String, message: String, changes: [FileChange])
    case githubBranch(repository: Repository, branch: String, fromSHA: String)
    case githubWrite(repository: Repository, branch: String?, path: String, message: String, originalSHA: String?, content: String)
    case githubDelete(repository: Repository, branch: String?, path: String, message: String, fileSHA: String)
    case serverCommand(server: Server, command: String)
    case sftp(server: Server, change: SFTPChange)
    case serverCredential(server: Server, credential: SSHCredential)
    case serverDelete(server: Server)
    case diskCredential(disk: Disk, credential: DiskCredential)
    case diskDelete(disk: Disk, retainsSharedSSH: Bool)
    case sessionDelete(title: String?, targetID: String)
    case favoriteDelete(name: String, kind: FavoriteKind, id: UUID)
    case subagentConfigure(model: SubagentModel?, thinking: Bool?)
}
