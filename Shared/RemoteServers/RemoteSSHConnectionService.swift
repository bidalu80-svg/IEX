import Citadel
import Crypto
import Foundation
import NIOCore
import NIOSSH
import SwiftUI

/// Owns authenticated SSH connections for the current app process. Credentials
/// are resolved locally; neither a password nor a private key is exposed to
/// chat, MCP, Rootfs, iCloud sync, or the app's logging facilities.
@MainActor
final class RemoteSSHConnectionService: ObservableObject {
    static let shared = RemoteSSHConnectionService()

    @Published private(set) var diagnostics: [UUID: [RemoteServerConnectionDiagnostic]] = [:]

    private var clients: [UUID: SSHClient] = [:]
    private var didAttemptConnectionRestore = false
    private let logger = AppLogger(category: "RemoteServers")

    private init() {}

    /// Restores the persisted connection state once per app process. A server
    /// with `lastConnectedAt` was connected when the previous process ended;
    /// `disconnect` clears that marker so a deliberate disconnect is durable.
    /// Each candidate is attempted exactly once, sequentially, and failures
    /// stay in the existing diagnostics instead of triggering alerts.
    func restoreConnectionsIfNeeded() async {
        guard !didAttemptConnectionRestore else { return }
        didAttemptConnectionRestore = true

        let candidates = RemoteServerStore.shared.servers.filter { $0.lastConnectedAt != nil }
        for server in candidates {
            do {
                try await connect(to: server)
            } catch {
                // `connect` records handshake failures it maps itself. Profile
                // validation and missing-credential failures happen before
                // that catch, so record them here to keep the existing
                // diagnostics section useful for automatic attempts too.
                if diagnostics[server.id]?.last?.phase != RemoteServerConnectionPhase.failed {
                    await append(
                        .init(phase: .failed, title: "连接失败", detail: error.localizedDescription),
                        for: server.id
                    )
                }
            }
        }
    }

    func connect(to server: RemoteServerProfile) async throws {
        try validate(server)
        await append(.init(phase: .resolving, title: "正在解析服务器地址"), for: server.id)
        await append(.init(phase: .connecting, title: "正在建立 SSH 连接"), for: server.id)

        let authentication = try authenticationMethod(for: server)
        let keyValidator = RemoteHostKeyValidator(expected: server.knownHost)
        await append(.init(phase: .verifyingHost, title: "正在验证服务器主机指纹"), for: server.id)

        do {
            let client = try await SSHClient.connect(
                host: server.normalizedHost,
                port: server.port,
                authenticationMethod: authentication,
                hostKeyValidator: .custom(keyValidator),
                reconnect: .never
            )
            clients[server.id] = client
            try RemoteServerStore.shared.markConnected(server.id)
            await append(.init(phase: .ready, title: "SSH 连接已建立"), for: server.id)
        } catch {
            let mappedError = mapConnectionError(error, validator: keyValidator, expected: server.knownHost)
            await append(.init(phase: .failed, title: "连接失败", detail: mappedError.localizedDescription), for: server.id)
            throw mappedError
        }
    }

    func disconnect(serverID: UUID) async {
        let client = clients.removeValue(forKey: serverID)
        do {
            try RemoteServerStore.shared.markDisconnected(serverID)
        } catch {
            // The in-memory marker is already cleared; keep the transport
            // teardown moving even if persisting the marker failed.
            logger.error("Could not clear remote server reconnect marker: \(error.localizedDescription)")
        }
        if let client {
            do {
                try await client.close()
            } catch {
                // The connection has already been removed from active state. A
                // transport-close error cannot resurrect it and is safe to ignore.
            }
        }
        RemoteServerSessionCredentials.shared.clear(for: serverID)
    }

    func isConnected(to serverID: UUID) -> Bool {
        clients[serverID] != nil
    }

    /// Executes a user-approved command. The caller must enforce AI policy and
    /// confirmation before invoking this API for model-proposed commands.
    func executeCommand(
        _ command: String,
        on serverID: UUID,
        maxResponseBytes: Int = 1_048_576
    ) async throws -> String {
        guard let client = clients[serverID] else {
            throw RemoteServerError.connectionFailed("服务器尚未连接")
        }
        let output = try await client.executeCommand(command, maxResponseSize: maxResponseBytes)
        return String(decoding: output.readableBytesView, as: UTF8.self)
    }

    func listDirectory(at path: String, on serverID: UUID) async throws -> [RemoteSFTPEntry] {
        try await withSFTP(on: serverID) { sftp in
            let directory = try await sftp.getRealPath(atPath: path)
            let response = try await sftp.listDirectory(atPath: directory)
            return response.flatMap(\.components).filter { component in
                component.filename != "." && component.filename != ".."
            }.map { component in
                let permissions: UInt32? = component.attributes.permissions ?? nil
                let isDirectory: Bool
                if let permissions {
                    isDirectory = (permissions & 0o170000) == 0o040000
                } else {
                    isDirectory = component.longname.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("d")
                }
                return RemoteSFTPEntry(
                    path: Self.remotePath(directory, appending: component.filename),
                    name: component.filename,
                    isDirectory: isDirectory,
                    size: component.attributes.size,
                    modifiedAt: component.attributes.accessModificationTime?.modificationTime,
                    permissions: permissions
                )
            }
            .sorted {
                if $0.isDirectory != $1.isDirectory { return $0.isDirectory }
                return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
            }
        }
    }

    /// A bounded download avoids turning a malicious or malformed SFTP size
    /// response into an unbounded in-memory allocation on the phone.
    func downloadFile(at remotePath: String, on serverID: UUID, maximumBytes: Int = 256 * 1_024 * 1_024) async throws -> Data {
        try await withSFTP(on: serverID) { sftp in
            let attributes = try await sftp.getAttributes(at: remotePath)
            if let size = attributes.size, size > UInt64(maximumBytes) {
                throw RemoteServerError.connectionFailed("文件超过本次下载上限（256 MB）")
            }
            return try await sftp.withFile(filePath: remotePath, flags: .read) { file in
                var data = Data()
                var offset: UInt64 = 0
                while true {
                    let chunk = try await file.read(from: offset, length: 32_000)
                    guard chunk.readableBytes > 0 else { break }
                    guard data.count <= maximumBytes - chunk.readableBytes else {
                        throw RemoteServerError.connectionFailed("文件超过本次下载上限（256 MB）")
                    }
                    data.append(contentsOf: chunk.readableBytesView)
                    offset += UInt64(chunk.readableBytes)
                }
                return data
            }
        }
    }

    func uploadFile(_ data: Data, to remotePath: String, on serverID: UUID, maximumBytes: Int = 256 * 1_024 * 1_024) async throws {
        guard data.count <= maximumBytes else {
            throw RemoteServerError.connectionFailed("文件超过本次上传上限（256 MB）")
        }
        try await withSFTP(on: serverID) { sftp in
            let buffer: ByteBuffer = {
                var value = ByteBufferAllocator().buffer(capacity: data.count)
                value.writeBytes(data)
                return value
            }()
            _ = try await sftp.withFile(filePath: remotePath, flags: [.write, .create, .truncate]) { file in
                try await file.write(buffer)
            }
        }
    }

    func createDirectory(at remotePath: String, on serverID: UUID) async throws {
        try await withSFTP(on: serverID) { sftp in
            try await sftp.createDirectory(atPath: remotePath)
        }
    }

    func renameItem(at remotePath: String, to newPath: String, on serverID: UUID) async throws {
        try await withSFTP(on: serverID) { sftp in
            try await sftp.rename(at: remotePath, to: newPath)
        }
    }

    func deleteItem(at remotePath: String, isDirectory: Bool, on serverID: UUID) async throws {
        try await withSFTP(on: serverID) { sftp in
            if isDirectory {
                try await sftp.rmdir(at: remotePath)
            } else {
                try await sftp.remove(at: remotePath)
            }
        }
    }

    func clearDiagnostics(for serverID: UUID) {
        diagnostics[serverID] = []
    }

    private func append(_ diagnostic: RemoteServerConnectionDiagnostic, for serverID: UUID) async {
        diagnostics[serverID, default: []].append(diagnostic)
    }

    private func validate(_ server: RemoteServerProfile) throws {
        guard server.enabled else {
            throw RemoteServerError.invalidProfile("此服务器已停用")
        }
        guard !server.normalizedHost.isEmpty, !server.username.isEmpty, (1...65_535).contains(server.port) else {
            throw RemoteServerError.invalidProfile("请检查主机、端口和用户名")
        }
    }

    private func withSFTP<Result>(
        on serverID: UUID,
        _ operation: @escaping @Sendable (SFTPClient) async throws -> Result
    ) async throws -> Result {
        guard let client = clients[serverID] else {
            throw RemoteServerError.connectionFailed("服务器尚未连接")
        }
        return try await client.withSFTP(operation)
    }

    nonisolated private static func remotePath(_ directory: String, appending name: String) -> String {
        directory == "/" ? "/\(name)" : directory + "/" + name
    }

    private func authenticationMethod(for server: RemoteServerProfile) throws -> SSHAuthenticationMethod {
        switch server.authentication {
        case .password:
            // Keychain is authoritative; the in-memory value is a fallback for
            // servers configured earlier in this process.
            let storedPassword = try? RemoteServerSecretStore.value(kind: .password, for: server.id)
            let memoryPassword = RemoteServerSessionCredentials.shared.password(for: server.id)
            guard let password = [storedPassword, memoryPassword]
                .compactMap({ $0 })
                .first(where: { !$0.isEmpty }) else {
                throw RemoteServerError.secretMissing
            }
            return .passwordBased(username: server.username, password: password)

        case .privateKey:
            guard let privateKey = try RemoteServerSecretStore.value(kind: .privateKey, for: server.id), !privateKey.isEmpty else {
                throw RemoteServerError.secretMissing
            }
            let passphrase = try RemoteServerSecretStore.value(kind: .privateKeyPassphrase, for: server.id)
            let decryptionKey = passphrase?.data(using: .utf8)

            switch try SSHKeyDetection.detectPrivateKeyType(from: privateKey) {
            case .rsa:
                return .rsa(
                    username: server.username,
                    privateKey: try Insecure.RSA.PrivateKey(sshRsa: privateKey, decryptionKey: decryptionKey)
                )
            case .ed25519:
                return .ed25519(
                    username: server.username,
                    privateKey: try Curve25519.Signing.PrivateKey(sshEd25519: privateKey, decryptionKey: decryptionKey)
                )
            case .ecdsaP256, .ecdsaP384, .ecdsaP521:
                // Citadel 0.11.1 can identify OpenSSH ECDSA files, but does
                // not expose an OpenSSH ECDSA private-key parser. Refuse
                // clearly instead of silently falling back to an unsafe route.
                throw RemoteServerError.unsupportedPrivateKey
            default:
                throw RemoteServerError.unsupportedPrivateKey
            }

        case .none:
            // Citadel 0.11.1 exposes the `none` offer through NIOSSH's
            // NIOSSHUserAuthenticationOffer.Offer, not as a public factory on
            // SSHAuthenticationMethod. This delegate sends exactly
            // `.user(username, offer: .none)` on the first challenge and then
            // fails the same way Citadel's own user-offer path does.
            return .custom(RemoteSSHNoneAuthentication(username: server.username))
        }
    }

    private func mapConnectionError(
        _ error: Error,
        validator: RemoteHostKeyValidator,
        expected: RemoteKnownHost?
    ) -> Error {
        if let remoteError = error as? RemoteServerError {
            return remoteError
        }
        if let received = validator.receivedKnownHost {
            guard let expected else {
                return RemoteServerError.hostKeyUntrusted(received)
            }
            if expected.algorithm != received.algorithm || expected.fingerprint != received.fingerprint {
                return RemoteServerError.hostKeyChanged(expected: expected, received: received)
            }
        }
        // Citadel.SSHClientError case 4 is allAuthenticationOptionsFailed:
        // every offered credential was rejected. Other "unsupported …"
        // cases mean the server did not accept the chosen method at all.
        // Both are authentication outcomes, not transport failures — never
        // surface the library's enum spelling to the user.
        if let sshError = error as? SSHClientError {
            switch sshError {
            case .allAuthenticationOptionsFailed,
                 .unsupportedPasswordAuthentication,
                 .unsupportedPrivateKeyAuthentication,
                 .unsupportedHostBasedAuthentication:
                return RemoteServerError.authenticationFailed
            case .channelCreationFailed:
                break
            }
        }
        if error is AuthenticationFailed {
            return RemoteServerError.authenticationFailed
        }
        if let citadelError = error as? CitadelError,
           case .unauthorized = citadelError {
            return RemoteServerError.authenticationFailed
        }
        // Some NIO wrappers preserve the enum spelling only in the textual
        // description; this is still an auth outcome, never a transport error.
        let description = String(describing: error)
        if description.contains("allAuthenticationOptionsFailed") {
            return RemoteServerError.authenticationFailed
        }
        return RemoteServerError.connectionFailed(error.localizedDescription)
    }
}

/// Sends a single `NIOSSHUserAuthenticationOffer.Offer.none` offer for servers
/// whose only supported method is "none". Citadel 0.11.1's
/// SSHAuthenticationMethod has no public none factory (its internal
/// `.user(username, offer:)` initializer is module-private), so the public
/// `.custom` entry point is used to produce the same wire offer.
private final class RemoteSSHNoneAuthentication: NIOSSHClientUserAuthenticationDelegate, @unchecked Sendable {
    private let username: String
    private var didOffer = false

    init(username: String) {
        self.username = username
    }

    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard !didOffer else {
            nextChallengePromise.fail(SSHClientError.allAuthenticationOptionsFailed)
            return
        }
        didOffer = true
        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(username: username, serviceName: "", offer: .none)
        )
    }
}

/// Translates a presented NIOSSH host key into the standard OpenSSH SHA-256
/// fingerprint and rejects anything other than the exact trusted identity.
/// The NIO callback can arrive off-main-thread, so the received public
/// metadata is protected with a lock. No secret key material ever enters it.
private final class RemoteHostKeyValidator: NIOSSHClientServerAuthenticationDelegate, @unchecked Sendable {
    private let expected: RemoteKnownHost?
    private let lock = NSLock()
    private var received: RemoteKnownHost?

    init(expected: RemoteKnownHost?) {
        self.expected = expected
    }

    var receivedKnownHost: RemoteKnownHost? {
        lock.lock()
        defer { lock.unlock() }
        return received
    }

    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let identity = try RemoteSSHHostFingerprint.make(from: hostKey)
            lock.lock()
            received = identity
            lock.unlock()

            guard let expected else {
                validationCompletePromise.fail(RemoteServerError.hostKeyUntrusted(identity))
                return
            }
            guard expected.algorithm == identity.algorithm, expected.fingerprint == identity.fingerprint else {
                validationCompletePromise.fail(RemoteServerError.hostKeyChanged(expected: expected, received: identity))
                return
            }
            validationCompletePromise.succeed(())
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}

private enum RemoteSSHHostFingerprint {
    static func make(from key: NIOSSHPublicKey) throws -> RemoteKnownHost {
        var buffer = ByteBufferAllocator().buffer(capacity: 512)
        key.write(to: &buffer)
        let raw = Data(buffer.readableBytesView)
        guard raw.count >= 4 else { throw RemoteServerError.connectionFailed("服务器返回了无效的主机密钥") }

        let algorithmLength = raw.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
        let start = 4
        let end = start + Int(algorithmLength)
        guard end <= raw.count, let algorithm = String(data: raw[start..<end], encoding: .utf8) else {
            throw RemoteServerError.connectionFailed("服务器返回了无法识别的主机密钥")
        }

        let digest = SHA256.hash(data: raw)
        let fingerprint = "SHA256:" + Data(digest).base64EncodedString().replacingOccurrences(of: "=", with: "")
        return RemoteKnownHost(algorithm: algorithm, fingerprint: fingerprint)
    }
}
