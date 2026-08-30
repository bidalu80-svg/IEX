import Foundation
import CryptoKit
import Network
import SMBClient

/// Errors surfaced by Ze-owned remote storage clients.
enum RemoteStorageClientError: LocalizedError, Sendable {
    case invalidConfiguration(String)
    case authenticationFailed
    case requestFailed(Int, String)
    case malformedResponse

    var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let detail): return detail
        case .authenticationFailed: return String(localized: "Remote authentication failed")
        case .requestFailed(let status, let detail): return "\(detail) (HTTP \(status))"
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
        guard URLComponents(string: "\(profile.useTLS ? "https" : "http")://\(profile.host)") != nil else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "Invalid server address"))
        }
        components.port = profile.port > 0 ? profile.port : (profile.useTLS ? 443 : 80)
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
        return try DAVXMLParser.parse(data: data, baseURL: url, requestedPath: normalize(path))
    }

    func upload(data: Data, to path: String) async throws {
        let url = try makeURL(path: path, trailingSlash: false)
        var request = makeRequest(url: url, method: "PUT")
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        let (_, response) = try await session.data(for: request)
        try validate(response)
    }

    func download(path: String) async throws -> Data {
        let request = makeRequest(url: try makeURL(path: path, trailingSlash: false), method: "GET")
        let (data, response) = try await session.data(for: request)
        try validate(response)
        return data
    }

    private func makeURL(path: String, trailingSlash: Bool) throws -> URL {
        guard var components = URLComponents(string: "\(profile.useTLS ? "https" : "http")://\(profile.host)") else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "Invalid server address"))
        }
        components.port = profile.port > 0 ? profile.port : (profile.useTLS ? 443 : 80)
        // The backup manager passes a complete remote path (including the
        // profile root), so do not prepend profile.path a second time.
        let base = "/"
        let child = normalize(path)
        let joined = child == "/" ? base : (base == "/" ? child : base + child)
        let escaped = joined.split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
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
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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
        do {
            try await client.login(username: profile.username, password: password)
            try await client.connectShare("\\\\\(profile.host)\\\(profile.share!)")
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
                RemoteSFTPEntry(path: directory + ($0.name == "/" ? "" : "/\($0.name)"), name: $0.name,
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

    private func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
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

    init(profile: RemoteStorageProfile, password: String) throws {
        guard profile.proto == .ftp, !profile.host.isEmpty, !profile.username.isEmpty else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "FTP 主机和用户名不能为空"))
        }
        self.profile = profile
        self.password = password
    }

    func testConnection() async throws { let connection = try await open(); connection.cancel() }

    func list(path: String) async throws -> [RemoteSFTPEntry] {
        let control = try await open()
        defer { control.cancel() }
        let dataConnection = try await passiveConnection(control)
        try await send("MLSD \(normalize(path))", on: control)
        _ = try await reply(on: control)
        let bytes = try await receiveAll(from: dataConnection)
        dataConnection.cancel()
        _ = try await reply(on: control)
        return parseListing(String(decoding: bytes, as: UTF8.self), base: normalize(path))
    }

    func upload(data: Data, to path: String) async throws {
        let control = try await open(); defer { control.cancel() }
        let dataConnection = try await passiveConnection(control)
        try await send("STOR \(normalize(path))", on: control)
        let initial = try await reply(on: control)
        guard initial.hasPrefix("150") || initial.hasPrefix("125") else { throw RemoteStorageClientError.requestFailed(0, initial) }
        try await send(data, on: dataConnection)
        dataConnection.cancel()
        let final = try await reply(on: control)
        guard final.hasPrefix("226") || final.hasPrefix("250") else { throw RemoteStorageClientError.requestFailed(0, final) }
    }

    func download(path: String) async throws -> Data {
        let control = try await open(); defer { control.cancel() }
        let dataConnection = try await passiveConnection(control)
        try await send("RETR \(normalize(path))", on: control)
        let initial = try await reply(on: control)
        guard initial.hasPrefix("150") || initial.hasPrefix("125") else { throw RemoteStorageClientError.requestFailed(0, initial) }
        let bytes = try await receiveAll(from: dataConnection)
        dataConnection.cancel()
        let final = try await reply(on: control)
        guard final.hasPrefix("226") || final.hasPrefix("250") else { throw RemoteStorageClientError.requestFailed(0, final) }
        return bytes
    }

    private func open() async throws -> NWConnection {
        let port = NWEndpoint.Port(rawValue: UInt16(profile.port > 0 ? profile.port : 21))!
        let connection = NWConnection(host: NWEndpoint.Host(profile.host), port: port, using: profile.useTLS ? .tcp : .tcp)
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
        try await send("TYPE I", on: connection); _ = try await reply(on: connection)
        let root = normalize(profile.path)
        if root != "/" { try await send("CWD \(root)", on: connection); let cwd = try await reply(on: connection); guard cwd.hasPrefix("250") else { throw RemoteStorageClientError.requestFailed(0, cwd) } }
        return connection
    }

    private func passiveConnection(_ control: NWConnection) async throws -> NWConnection {
        try await send("PASV", on: control)
        let response = try await reply(on: control)
        guard let open = response.firstIndex(of: "("), let close = response.firstIndex(of: ")") else { throw RemoteStorageClientError.malformedResponse }
        let values = response[response.index(after: open)..<close].split(separator: ",").compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard values.count == 6, let port = NWEndpoint.Port(rawValue: values[4] * 256 + values[5]) else { throw RemoteStorageClientError.malformedResponse }
        let host = "\(values[0]).\(values[1]).\(values[2]).\(values[3])"
        let connection = NWConnection(host: NWEndpoint.Host(host), port: port, using: .tcp)
        try await waitReady(connection)
        return connection
    }

    private func waitReady(_ connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: continuation.resume()
                case .failed(let error): continuation.resume(throwing: RemoteStorageClientError.requestFailed(0, error.localizedDescription))
                case .cancelled: continuation.resume(throwing: RemoteStorageClientError.requestFailed(0, "FTP 连接已取消"))
                default: break
                }
            }
            connection.start(queue: .global())
        }
    }

    private func send(_ command: String, on connection: NWConnection) async throws {
        try await send(Data((command + "\r\n").utf8), on: connection)
    }

    private func send(_ data: Data, on connection: NWConnection) async throws {
        try await withCheckedThrowingContinuation { continuation in
            connection.send(content: data, completion: .contentProcessed { error in
                if let error { continuation.resume(throwing: RemoteStorageClientError.requestFailed(0, error.localizedDescription)) }
                else { continuation.resume() }
            })
        }
    }

    private func reply(on connection: NWConnection) async throws -> String {
        var data = Data()
        while true {
            let chunk = try await receive(from: connection)
            data.append(chunk)
            if let text = String(data: data, encoding: .utf8), text.contains("\r\n") {
                let lines = text.components(separatedBy: "\r\n").filter { !$0.isEmpty }
                if let first = lines.first, first.count >= 3, Int(first.prefix(3)) != nil {
                    if first.count >= 4 && first[first.index(first.startIndex, offsetBy: 3)] == "-" {
                        if lines.contains(where: { $0.hasPrefix(String(first.prefix(3)) + " ") }) { return lines.joined(separator: "\n") }
                    } else { return String(first) }
                }
            }
        }
    }

    private func receive(from connection: NWConnection) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) { data, _, complete, error in
                if let error { continuation.resume(throwing: RemoteStorageClientError.requestFailed(0, error.localizedDescription)) }
                else if let data, !data.isEmpty { continuation.resume(returning: data) }
                else if complete { continuation.resume(returning: Data()) }
                else { continuation.resume(throwing: RemoteStorageClientError.malformedResponse) }
            }
        }
    }

    private func receiveAll(from connection: NWConnection) async throws -> Data {
        var result = Data()
        while true {
            let chunk = try await receive(from: connection)
            if chunk.isEmpty { break }
            result.append(chunk)
        }
        return result
    }

    private func parseListing(_ text: String, base: String) -> [RemoteSFTPEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: ";")
            guard let name = fields.last.map(String.init), !name.isEmpty else { return nil }
            let isDirectory = fields.contains { $0.lowercased().hasPrefix("type=dir") }
            let size = fields.first { $0.lowercased().hasPrefix("size=") }.flatMap { UInt64($0.dropFirst(5)) }
            return RemoteSFTPEntry(path: base == "/" ? "/\(name)" : "\(base)/\(name)", name: name, isDirectory: isDirectory, size: size, modifiedAt: nil, permissions: nil)
        }
    }

    private func normalize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }
}

private enum DAVXMLParser {
    final class Delegate: NSObject, XMLParserDelegate {
        var entries: [(href: String, name: String, size: UInt64?, modified: Date?, directory: Bool)] = []
        var current: (String, String, UInt64?, Date?, Bool)?
        var element = ""
        var text = ""

        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String : String] = [:]) {
            let local = (qualifiedName ?? name).split(separator: ":").last.map(String.init) ?? name
            element = local.lowercased()
            if element == "response" { current = ("", "", nil, nil, false) }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            guard var current else { text = ""; return }
            let local = (qualifiedName ?? name).split(separator: ":").last.map(String.init)?.lowercased() ?? name.lowercased()
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch local {
            case "href": current.0 = value
            case "displayname": current.1 = value
            case "getcontentlength": current.2 = UInt64(value)
            case "getlastmodified": current.3 = DAVXMLParser.date(value)
            case "collection": current.4 = true
            case "response": entries.append(current)
            default: break
            }
            self.current = current
            text = ""
        }
    }

    static func parse(data: Data, baseURL: URL, requestedPath: String) throws -> [RemoteSFTPEntry] {
        let delegate = Delegate()
        let parser = XMLParser(data: data); parser.delegate = delegate
        guard parser.parse() else { throw RemoteStorageClientError.malformedResponse }
        return delegate.entries.compactMap { entry in
            guard let hrefURL = URL(string: entry.href, relativeTo: baseURL)?.absoluteURL else { return nil }
            let name = entry.name.isEmpty ? hrefURL.lastPathComponent : entry.name
            guard !name.isEmpty, name != requestedPath.split(separator: "/").last.map(String.init) else { return nil }
            return RemoteSFTPEntry(path: hrefURL.path, name: name, isDirectory: entry.directory,
                                   size: entry.size, modifiedAt: entry.modified, permissions: nil)
        }
    }

    private static func date(_ value: String) -> Date? {
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        return formatter.date(from: value)
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
        self.profile = profile
        self.secret = secret
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 600
        self.session = URLSession(configuration: config)
    }

    func testConnection() async throws { _ = try await list(path: profile.path) }

    func list(path: String) async throws -> [RemoteSFTPEntry] {
        var query = "list-type=2"
        let prefix = key(path)
        if !prefix.isEmpty { query += "&prefix=\(percentQuery(prefix))" }
        let (data, response) = try await send(method: "GET", key: "", query: query)
        try validate(response)
        return parseList(data: data)
    }

    func upload(data: Data, to path: String) async throws {
        let (_, response) = try await send(method: "PUT", key: key(path), body: data)
        try validate(response)
    }

    func download(path: String) async throws -> Data {
        let (data, response) = try await send(method: "GET", key: key(path))
        try validate(response)
        return data
    }

    private func key(_ path: String) -> String {
        let value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return value
    }

    private func endpoint(for objectKey: String) throws -> URL {
        guard let base = URL(string: "\(profile.useTLS ? "https" : "http")://\(profile.host)") else {
            throw RemoteStorageClientError.invalidConfiguration(String(localized: "Invalid S3 endpoint"))
        }
        let bucket = profile.bucket!.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let encoded = ([bucket] + objectKey.split(separator: "/").map(String.init))
            .map { $0.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? $0 }
            .joined(separator: "/")
        return base.appendingPathComponent(encoded)
    }

    private func send(method: String, key: String, query: String? = nil, body: Data? = nil) async throws -> (Data, URLResponse) {
        let url = try endpoint(for: key) 
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if let query { request.url = URL(string: url.absoluteString + "?" + query) }
        let payloadHash = SHA256.hash(data: body ?? Data()).hex
        let region = profile.region?.isEmpty == false ? profile.region! : "us-east-1"
        let now = Date()
        let iso = ISO8601DateFormatter(); iso.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate, .withColonSeparatorInTime]
        let amzDate = iso.string(from: now).replacingOccurrences(of: "-", with: "").replacingOccurrences(of: ":", with: "")
            .replacingOccurrences(of: "Z", with: "") + "Z"
        let shortDate = String(amzDate.prefix(8))
        let host = url.host ?? profile.host
        request.setValue(host, forHTTPHeaderField: "Host")
        request.setValue(amzDate, forHTTPHeaderField: "x-amz-date")
        request.setValue(payloadHash, forHTTPHeaderField: "x-amz-content-sha256")
        let canonicalURI = url.percentEncodedPath.isEmpty ? "/" : (url.percentEncodedPath)
        let canonicalQuery = canonicalQueryString(query)
        let canonicalHeaders = "host:\(host)\nx-amz-content-sha256:\(payloadHash)\nx-amz-date:\(amzDate)\n"
        let signedHeaders = "host;x-amz-content-sha256;x-amz-date"
        let canonical = [method, canonicalURI, canonicalQuery, canonicalHeaders, signedHeaders, payloadHash].joined(separator: "\n")
        let scope = "\(shortDate)/\(region)/\(service)/aws4_request"
        let credential = "\(profile.username)/\(scope)"
        let hash = SHA256.hash(data: Data(canonical.utf8)).hex
        let stringToSign = "AWS4-HMAC-SHA256\n\(amzDate)\n\(scope)\n\(hash)"
        let signingKey = Self.signingKey(secret: secret, date: shortDate, region: region, service: service)
        let signature = Self.hmac(key: signingKey, data: stringToSign).hex
        request.setValue("AWS4-HMAC-SHA256 Credential=\(credential), SignedHeaders=\(signedHeaders), Signature=\(signature)", forHTTPHeaderField: "Authorization")
        return try await session.data(for: request)
    }

    private func validate(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw RemoteStorageClientError.malformedResponse }
        if http.statusCode == 401 || http.statusCode == 403 { throw RemoteStorageClientError.authenticationFailed }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteStorageClientError.requestFailed(http.statusCode, String(localized: "S3 request failed"))
        }
    }

    private func parseList(data: Data) -> [RemoteSFTPEntry] {
        guard let xml = String(data: data, encoding: .utf8) else { return [] }
        let names = xml.components(separatedBy: "<Key>").dropFirst().compactMap { $0.components(separatedBy: "</Key>").first }
        return names.map { name in
            RemoteSFTPEntry(path: "/" + name, name: (name as NSString).lastPathComponent,
                            isDirectory: name.hasSuffix("/"), size: nil, modifiedAt: nil, permissions: nil)
        }
    }

    private func percentQuery(_ value: String) -> String {
        rfc3986(value)
    }

    private func canonicalQueryString(_ query: String?) -> String {
        guard let query, !query.isEmpty else { return "" }
        return query.split(separator: "&", omittingEmptySubsequences: false).map { part in
            let pair = part.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            let name = rfc3986(String(pair[0]).removingPercentEncoding ?? String(pair[0]))
            let value = pair.count > 1 ? rfc3986(String(pair[1]).removingPercentEncoding ?? String(pair[1])) : ""
            return (name, value)
        }.sorted { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
            .map { "\($0.0)=\($0.1)" }.joined(separator: "&")
    }

    private func rfc3986(_ value: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
        return value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
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
