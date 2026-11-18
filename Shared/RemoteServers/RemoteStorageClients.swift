import Foundation
import CryptoKit
import Network
import Security
import SMBClient

/// Errors surfaced by Ze-owned remote storage clients.
enum RemoteStorageClientError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case authenticationFailed
    case requestFailed(Int, String)
    case malformedResponse
    case downloadTooLarge(Int)

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return detail
        case .authenticationFailed: return String(localized: "Remote authentication failed")
        case .requestFailed(let status, let detail): return "\(detail) (HTTP \(status))"
        case .downloadTooLarge(let limit): return "文件超过下载上限（\(limit) 字节）"
        case .malformedResponse: return String(localized: "The remote server returned an invalid response")
        }
    }
}

/// Minimal WebDAV client using URLSession and the standard DAV verbs. It is
/// intentionally independent from Files providers and works with Nextcloud,
/// ownCloud, Synology and compatible DAV endpoints.
final actor WebDAVRemoteStorageClient: RemoteStorageClient {
    private let profile: RemoteStorageProfile
    private let password: String
    private let session: URLSession

    init(profile: RemoteStorageProfile, password: String) throws {
        guard profile.proto == .webdav else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "Invalid WebDAV profile"))
        }
        guard (try? RemoteStorageEndpoint.components(profile)) != nil else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "Invalid server address"))
        }
        var config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 45
        config.timeoutIntervalForResource = 300
        self.profile = profile
        self.password = password
        self.session = URLSession(configuration: config)
    }

    func testConnection() async throws {
        _ = try await list(path: profile.path)
    }

    func list(path: String) async throws -> [RemoteSFTPEntry] {
        let url = try makeURL(path: path, trailingSlash: true)
        var request = makeRequest(url: url, method: "PROPFIND")
        request.setValue("1", forHTTPHeaderField: "Depth")
        request.setValue("application/xml", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data("""
        <?xml version="1.0" encoding="utf-8" ?>
        <d:propfind xmlns:d="DAV:"><d:prop><d:displayname/><d:getcontentlength/><d:getlastmodified/><d:resourcetype/></d:prop></d:propfind>
        """.utf8)
        let (data, response) = try await session.data(for: request)
        try validate(response)
        guard let http = response as? HTTPURLResponse, http.statusCode == 207 else {
            throw RemoteStorageClientError.malformedResponse
        }
        return try RemoteDAVListing.parse(data, baseURL: url)
    }

    func upload(data: Data, to path: String) async throws {
        let url = try makeURL(path: path, trailingSlash: false)
        var request = makeRequest(url: url, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func download(path: String) async throws -> Data { try await download(path: path, maximumBytes: .max) }

    func download(path: String, maximumBytes: Int) async throws -> Data {
        let request = makeRequest(url: try makeURL(path: path, trailingSlash: false), method: "GET")
        return try await RemoteStorageHTTP.download(request, session: session, maximumBytes: maximumBytes)
    }

    private func makeURL(path: String, trailingSlash: Bool) throws -> URL {
        var components = try RemoteStorageEndpoint.components(profile)
        components.port = profile.port > 0 ? profile.port : (profile.useTLS ? 443 : 80)
        // The backup manager passes a complete remote path (including the
        // profile root), so do not prepend profile.path a second time.
        let base = "/"
        let child = normalize(path)
        let joined = child == "/" ? base : (base == "/" ? child : base + child)
        let escaped = joined.split(separator: "/", omittingEmptySubsequences: true)
            .map { RemoteStorageEndpoint.encode(String($0)) }
            .joined(separator: "/")
        components.percentEncodedPath = "/" + escaped + (trailingSlash && !escaped.isEmpty ? "/" : "")
        guard let url = components.url else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "Invalid remote path"))
        }
        return url
    }

    private func makeRequest(url: URL, method: String) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpMethod = method
        let token = Data("\(profile.username):\(password)".utf8).base64EncodedString()
        request.setValue("Basic \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else {
            throw RemoteStorageClientError.malformedResponse
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw RemoteStorageClientError.authenticationFailed
        }
        guard (200...299).contains(http.statusCode) || http.statusCode == 207 else {
            throw RemoteStorageClientError.requestFailed(http.statusCode, String(localized: "Remote request failed"))
        }
    }

    private func normalize(_ value: String) -> String {
        let trimmed = value
        guard !trimmed.isEmpty || value == "/" else { return "/" }
        var result = trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
        while result.count > 1 && result.hasSuffix("/") { result.removeLast() }
        return result
    }
}

/// SMB2 client adapter. The SMBClient package only handles the wire protocol;
/// this adapter translates it to Ze's common backup contract.
final actor SMBRemoteStorageClient: RemoteStorageClient {
    private let profile: RemoteStorageProfile
    private let password: String
    private let client: SMBClient
    private var connected = false

    init(profile: RemoteStorageProfile, password: String) throws {
        guard profile.proto == .smb, let share = profile.share, !share.isEmpty else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "SMB 共享名称不能为空"))
        }
        guard !profile.host.isEmpty, !profile.username.isEmpty else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "SMB 主机和用户名不能为空"))
        }
        self.profile = profile
        self.password = password
        self.client = SMBClient(host: profile.host, port: profile.port > 0 ? profile.port : 445)
    }

    private func connect() async throws {
        guard !connected else { return }
        do {
            try await client.login(username: profile.username, password: password)
            try await client.connectShare("\\\\\(profile.host)\\\(profile.share!)")
            connected = true
        } catch {
            throw RemoteStorageClientError.requestFailed(0, error.localizedDescription)
        }
    }

    func testConnection() async throws { try await connect(); _ = try await client.listDirectory(path: "/") }

    func list(path: String) async throws -> [RemoteSFTPEntry] {
        try await connect()
        let directory = normalize(path)
        do {
            return try await client.listDirectory(path: directory).map {
                RemoteSFTPEntry(path: (directory == "/" ? "" : directory) + "/\($0.name)", name: $0.name,
                                 isDirectory: $0.isDirectory, size: $0.size, modifiedAt: $0.lastWriteTime, permissions: nil)
            }
        } catch { throw RemoteStorageClientError.requestFailed(0, error.localizedDescription) }
    }

    func upload(data: Data, to path: String) async throws {
        try await connect()
        do { try await client.upload(content: data, path: normalize(path)) }
        catch { throw RemoteStorageClientError.requestFailed(0, error.localizedDescription) }
    }

    func download(path: String) async throws -> Data {
        try await connect()
        do { return try await client.download(path: normalize(path)) }
        catch { throw RemoteStorageClientError.requestFailed(0, error.localizedDescription) }
    }

    func download(path: String, maximumBytes: Int) async throws -> Data {
        // SMBClient's Data API is not streaming. Require known size up front,
        // then check actual bytes as well; transport allocation remains a
        // documented SMB limitation until its dependency is verified.
        let parent = (path as NSString).deletingLastPathComponent
        let name = (path as NSString).lastPathComponent
        guard let entry = try await list(path: parent).first(where: { $0.name == name }), !entry.isDirectory else {
            throw RemoteStorageClientError.invalidConfiguration("SMB 文件不存在或不是普通文件")
        }
        guard let size = entry.size, size <= UInt64(maximumBytes) else { throw RemoteStorageClientError.downloadTooLarge(maximumBytes) }
        let bytes = try await download(path: path)
        guard bytes.count <= maximumBytes else { throw RemoteStorageClientError.downloadTooLarge(maximumBytes) }
        return bytes
    }

    private func normalize(_ value: String) -> String {
        let trimmed = value
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }
}

/// Small FTP/FTPS client implemented with Network.framework. It supports the
/// commands required by encrypted backup destinations (USER/PASS, CWD, MLSD,
/// LIST, RETR, STOR and passive data connections).
final actor FTPRemoteStorageClient: RemoteStorageClient {
    private let profile: RemoteStorageProfile
    private let password: String
    private var replies: [ObjectIdentifier: Data] = [:]

    init(profile: RemoteStorageProfile, password: String) throws {
        guard profile.proto == .ftp, !profile.host.isEmpty, !profile.username.isEmpty else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "FTP 主机和用户名不能为空"))
        }
        guard (1...65535).contains(profile.port), !profile.host.contains("://"),
              !profile.host.contains("/"), !profile.host.contains("@"),
              !profile.username.contains(where: { $0.isNewline }),
              !password.contains(where: { $0.isNewline }) else {
            throw RemoteStorageClientError.invalidConfiguration("FTP 地址、端口或凭据无效")
        }
        // Network.framework cannot upgrade a live TCP stream with AUTH TLS.
        // Support implicit FTPS and explicitly refuse an insecure downgrade.
        guard !profile.useTLS || profile.port == 990 else {
            throw RemoteStorageClientError.invalidConfiguration("FTPS 仅支持隐式 TLS（990）；显式 AUTH TLS 未实现，连接已拒绝")
        }
        self.profile = profile
        self.password = password
    }

    func testConnection() async throws { let connection = try await open(); close(connection) }

    func list(path: String) async throws -> [RemoteSFTPEntry] {
        let control = try await open()
        defer { close(control) }
        var (dataConnection, dataReady) = try await passiveConnection(control)
        defer { dataReady.cancel(); dataConnection.cancel() }
        try await send("MLSD \(normalize(path))", on: control)
        var initial = try await reply(on: control)
        var machineListing = true
        if initial.hasPrefix("500") || initial.hasPrefix("502") || initial.hasPrefix("504") {
            dataConnection.cancel()
            dataReady.cancel()
            (dataConnection, dataReady) = try await passiveConnection(control)
            try await send("LIST \(normalize(path))", on: control)
            initial = try await reply(on: control)
            machineListing = false
        }
        guard initial.hasPrefix("150") || initial.hasPrefix("125") else { throw RemoteStorageClientError.requestFailed(0, initial) }
        try await dataReady.value
        let bytes = try await receiveAll(from: dataConnection, maximumBytes: 16 * 1024 * 1024)
        let final = try await reply(on: control)
        guard final.hasPrefix("226") || final.hasPrefix("250") else { throw RemoteStorageClientError.requestFailed(0, final) }
        guard let listing = String(data: bytes, encoding: .utf8) else {
            throw RemoteStorageClientError.invalidConfiguration("FTP 目录名称不是 UTF-8；无法安全读取该目录")
        }
        return try RemoteFTPListing.parse(listing, base: normalize(path), machine: machineListing)
    }

    func upload(data: Data, to path: String) async throws {
        let control = try await open(); defer { close(control) }
        let (dataConnection, dataReady) = try await passiveConnection(control)
        defer { dataReady.cancel(); dataConnection.cancel() }
        try await send("STOR \(normalize(path))", on: control)
        let initial = try await reply(on: control)
        guard initial.hasPrefix("150") || initial.hasPrefix("125") else { throw RemoteStorageClientError.requestFailed(0, initial) }
        try await dataReady.value
        try await send(data, on: dataConnection)
        dataConnection.cancel()
        let final = try await reply(on: control)
        guard final.hasPrefix("226") || final.hasPrefix("250") else { throw RemoteStorageClientError.requestFailed(0, final) }
    }

    func download(path: String) async throws -> Data { try await download(path: path, maximumBytes: .max) }

    func download(path: String, maximumBytes: Int) async throws -> Data {
        let control = try await open(); defer { close(control) }
        let (dataConnection, dataReady) = try await passiveConnection(control)
        defer { dataReady.cancel(); dataConnection.cancel() }
        try await send("RETR \(normalize(path))", on: control)
        let initial = try await reply(on: control)
        guard initial.hasPrefix("150") || initial.hasPrefix("125") else { throw RemoteStorageClientError.requestFailed(0, initial) }
        try await dataReady.value
        let bytes = try await receiveAll(from: dataConnection, maximumBytes: maximumBytes)
        dataConnection.cancel()
        let final = try await reply(on: control)
        guard final.hasPrefix("226") || final.hasPrefix("250") else { throw RemoteStorageClientError.requestFailed(0, final) }
        return bytes
    }

    private func open() async throws -> NWConnection {
        let port = NWEndpoint.Port(rawValue: UInt16(profile.port > 0 ? profile.port : 21))!
        let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: port, using: parameters())
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { connection.cancel() }
        do {
        try await waitReady(connection)
        let greeting = try await reply(on: connection)
        guard greeting.hasPrefix("220") else { throw RemoteStorageClientError.requestFailed(0, greeting) }
        try await send("USER \(profile.username)", on: connection)
        let userReply = try await reply(on: connection)
        if userReply.hasPrefix("331") {
            try await send("PASS \(password)", on: connection)
            let passReply = try await reply(on: connection)
            guard passReply.hasPrefix("230") else { throw RemoteStorageClientError.authenticationFailed }
        } else if !userReply.hasPrefix("230") {
            throw RemoteStorageClientError.authenticationFailed
        }
        for command in (profile.useTLS ? ["PBSZ 0", "PROT P", "TYPE I"] : ["TYPE I"]) {
            try await send(command, on: connection)
            let response = try await reply(on: connection)
            guard response.hasPrefix("200") else { throw RemoteStorageClientError.requestFailed(0, response) }
        }
        return connection
        } catch { close(connection); throw error }
    }

    private func close(_ connection: NWConnection) {
        replies.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    private func parameters() -> NWParameters {
        guard profile.useTLS else { return .tcp }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, profile.host)
        return NWParameters(tls: tls, tcp: NWProtocolTCP.Options())
    }

    private func passiveConnection(_ control: NWConnection) async throws -> (NWConnection, Task<Void, Error>) {
        // EPSV works through NAT and with IPv6. Ignore PASV's advertised host:
        // connect only to the configured control host, avoiding FTP bounce.
        try await send("EPSV", on: control)
        let response = try await reply(on: control)
        let portNumber: UInt16
        if response.hasPrefix("229") {
            portNumber = try RemoteFTPPassivePort.extended(response)
        } else {
            try await send("PASV", on: control)
            portNumber = try RemoteFTPPassivePort.classic(await reply(on: control))
        }
        guard let port = NWEndpoint.Port(rawValue: portNumber) else { throw RemoteStorageClientError.malformedResponse }
        let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: port, using: parameters())
        DispatchQueue.global().asyncAfter(deadline: .now() + 120) { connection.cancel() }
        let readiness = Task { try await self.waitReady(connection) }
        return (connection, readiness)
    }

    private func waitReady(_ connection: NWConnection) async throws {
        let gate = RemoteFTPReadyGate()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                gate.install(continuation)
                connection.stateUpdateHandler = { state in
                    switch state {
                    case .ready: gate.finish(nil)
                    case .failed(let error): gate.finish(error)
                    case .cancelled: gate.finish(CancellationError())
                    default: break
                    }
                }
                connection.start(queue: .global())
                DispatchQueue.global().asyncAfter(deadline: .now() + 30) {
                    if gate.finish(RemoteStorageClientError.invalidConfiguration("FTP 连接超时")) { connection.cancel() }
                }
            }
        } onCancel: { connection.cancel() }
    }

    private func send(_ command: String, on connection: NWConnection) async throws {
        guard !command.contains(where: { $0.isNewline || $0 == "\0" }) else { throw RemoteStorageClientError.invalidConfiguration("FTP 命令包含无效字符") }
        try await send(Data((command + "\r\n").utf8), on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: RemoteStorageClientError.requestFailed(0, error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    private func reply(on connection: NWConnection) async throws -> String {
        let id = ObjectIdentifier(connection)
        var buffer = replies.removeValue(forKey: id) ?? Data()
        while true {
            if let framed = try RemoteFTPReply.consume(&buffer) {
                replies[id] = buffer
                return framed
            }
            let chunk = try await receive(from: connection)
            guard !chunk.isEmpty else { throw RemoteStorageClientError.invalidConfiguration("FTP 控制连接提前关闭") }
            guard buffer.count + chunk.count <= 1024 * 1024 else { throw RemoteStorageClientError.malformedResponse }
            buffer.append(chunk)
        }
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, Error>) in
                connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                    if let error { continuation.resume(throwing: error) }
                    else if let data, !data.isEmpty { continuation.resume(returning: data) }
                    else if complete { continuation.resume(returning: Data()) }
                    else { continuation.resume(throwing: RemoteStorageClientError.malformedResponse) }
                }
            }
        } onCancel: { connection.cancel() }
    }

    private func receiveAll(from connection: NWConnection, maximumBytes: Int) async throws -> Data {
        var result = Data()
        while true {
            let chunk = try await receive(from: connection)
            if chunk.isEmpty { break }
            guard chunk.count <= maximumBytes - result.count else { connection.cancel(); throw RemoteStorageClientError.downloadTooLarge(maximumBytes) }
            try Task.checkCancellation()
            result.append(chunk)
        }
        return result
    }

    private func normalize(_ value: String) -> String {
        let trimmed = value
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }
}

/// S3-compatible object client using AWS Signature V4. Works with AWS S3,
/// MinIO, Cloudflare R2, Wasabi and OSS/COS endpoints that expose S3 APIs.
final actor S3RemoteStorageClient: RemoteStorageClient {
    private let profile: RemoteStorageProfile
    private let secret: String
    private let session: URLSession
    private let service = "s3"

    init(profile: RemoteStorageProfile, secret: String) throws {
        guard profile.proto == .s3, let bucket = profile.bucket, !bucket.isEmpty else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "S3 bucket is required"))
        }
        guard !profile.username.isEmpty, !secret.isEmpty else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "S3 access key and secret are required"))
        }
        _ = try RemoteStorageEndpoint.components(profile)
        guard !bucket.contains("/"), bucket != ".", bucket != ".." else { throw RemoteStorageClientError.invalidConfiguration("S3 bucket 无效") }
        self.profile = profile
        self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func testConnection() async throws { _ = try await list(path: profile.path) }

    func list(path: String) async throws -> [RemoteSFTPEntry] {
        let directory = key(path)
        let prefix = directory.isEmpty ? "" : directory + "/"
        var token: String?
        var seen = Set<String>()
        var entries: [RemoteSFTPEntry] = []
        repeat {
            var query = "list-type=2&delimiter=%2F&prefix=\(percentQuery(prefix))"
            if let token { query += "&continuation-token=\(percentQuery(token))" }
            let (data, response) = try await send(method: "GET", key: "", query: query)
            try validate(response)
            let page = try RemoteS3Listing.parse(data, prefix: prefix)
            entries.append(contentsOf: page.entries)
            token = page.nextToken
            if let token, !seen.insert(token).inserted { throw RemoteStorageClientError.malformedResponse }
            try Task.checkCancellation()
        } while token != nil
        if entries.isEmpty && !prefix.isEmpty {
            // Empty prefixes have no directory identity unless a marker exists.
            // A nonexistent path must not be reported as a verified empty folder.
            let (_, response) = try await send(method: "HEAD", key: prefix)
            try validate(response)
        }
        return entries
    }

    func upload(data: Data, to path: String) async throws {
        let (_, response) = try await send(method: "PUT", key: key(path), body: data)
        try validate(response)
    }

    func download(path: String) async throws -> Data { try await download(path: path, maximumBytes: .max) }

    func download(path: String, maximumBytes: Int) async throws -> Data {
        let request = try signedRequest(method: "GET", key: key(path))
        return try await RemoteStorageHTTP.download(request, session: session, maximumBytes: maximumBytes)
    }

    private func key(_ path: String) -> String {
        let value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value
    }

    private func endpoint(for objectKey: String) throws -> URL {
        var components = try RemoteStorageEndpoint.components(profile)
        components.percentEncodedPath = "/" + ([profile.bucket!] + objectKey.components(separatedBy: "/")).map(RemoteStorageEndpoint.encode).joined(separator: "/")
        if objectKey.isEmpty { components.percentEncodedPath = "/" + RemoteStorageEndpoint.encode(profile.bucket!) }
        guard let url = components.url else { throw RemoteStorageClientError.malformedResponse }
        return url
    }

    private func send(method: String, key: String, query: String? = nil, body: Data? = nil) async throws -> (Data, URLResponse) {
        try await session.data(for: signedRequest(method: method, key: key, query: query, body: body))
    }

    private func signedRequest(method: String, key: String, query: String? = nil, body: Data? = nil) throws -> URLRequest {
        let url = try endpoint(for: key)
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)!
        let canonicalQuery = canonicalQueryString(query)
        components.percentEncodedQuery = canonicalQuery.isEmpty ? nil : canonicalQuery
        var request = URLRequest(url: components.url!)
        request.httpMethod = method
        request.httpBody = body
        let payloadHash = SHA256.hash(data: body ?? Data()).hex
        let region = profile.region?.isEmpty == false ? profile.region! : "us-east-1"
        let now = Date()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let amzDate = iso.string(from: now).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "Z", with: "") + "Z"
        let shortDate = String(amzDate.prefix(8))
        let host = components.percentEncodedHost! + (url.port.map { ":\($0)" } ?? "")
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        let canonicalURI = components.percentEncodedPath
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonical = [method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let credential = "\(profile.username)/\(scope)"
        let hash = SHA256.hash(data: Data(canonical.utf8)).hex
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(hash)"
        let signingKey = Self.signingKey(secret: secret, date: shortDate, region: region, service: service)
        let signature = Data(Self.hmac(key: signingKey, data: stringToSign)).map { String(format: "%02x", $0) }.joined()
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credential), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return request
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteStorageClientError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw RemoteStorageClientError.authenticationFailed }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteStorageClientError.requestFailed(http.statusCode, String(localized: "S3 request failed"))
        }
    }

    private func percentQuery(_ value: String) -> String {
        rfc3986(value)
    }

    private func canonicalQueryString(_ query: String?) -> String {
        guard let query, !query.isEmpty else { return "" }
        var pairs: [(String, String)] = []
        for part in query.split(separator: "&", omittingEmptySubsequences: false) {
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = rfc3986(String(pair[0]).removingPercentEncoding ?? String(pair[0]))
            let value = pair.count > 1 ? rfc3986(String(pair[1]).removingPercentEncoding ?? String(pair[1])) : ""
            pairs.append((name, value))
        }
        pairs.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        return pairs.map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private func rfc3986(_ value: String) -> String {
        RemoteStorageEndpoint.encode(value)
    }

    private static func hmac(key: Data, data: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(data.utf8), using: SymmetricKey(data: key)))
    }

    private static func signingKey(secret: String, date: String, region: String, service: String) -> Data {
        let kDate = hmac(key: Data(("AWS4" + secret).utf8), data: date)
        let kRegion = hmac(key: kDate, data: region)
        let kService = hmac(key: kRegion, data: service)
        return hmac(key: kService, data: "aws4_request")
    }
}

private extension Digest where Self == SHA256.Digest {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
