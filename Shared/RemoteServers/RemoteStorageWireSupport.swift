import Foundation

/// Host fields contain a hostname only; paths, userinfo and ports have their
/// own fields. This prevents credentials or an ignored URL suffix in endpoints.
enum RemoteStorageEndpoint {
    static func components(_ profile: RemoteStorageProfile) throws -> URLComponents {
        let host = profile.host
        guard !host.isEmpty, host == host.trimmingCharacters(in: .whitespacesAndNewlines),
              !host.contains(where: { $0.isWhitespace || $0.isNewline }),
              !host.contains("/"), !host.contains("@"), !host.contains("?"), !host.contains("#"),
              (1...65535).contains(profile.port) else {
            throw RemoteStorageClientError.invalidConfiguration("请输入纯主机名和有效端口；路径请填写到文件夹路径")
        }
        guard !host.contains(":"), !host.contains("\\"), !host.contains("%"),
              !host.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw RemoteStorageClientError.invalidConfiguration("主机名不可包含端口或特殊路径字符")
        }
        var components = URLComponents()
        components.scheme = profile.useTLS ? "https" : "http"
        components.host = host
        components.port = profile.port
        guard let url = components.url, url.host != nil else { throw RemoteStorageClientError.malformedResponse }
        return components
    }

    static func encode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"))!
    }
}

enum RemoteStorageHTTP {
    static func download(_ request: URLRequest, session: URLSession, maximumBytes: Int) async throws -> Data {
        let (bytes, response) = try await session.bytes(for: request)
        guard let http = response as? HTTPURLResponse else { throw RemoteStorageClientError.malformedResponse }
        guard (200...299).contains(http.statusCode) else {
            throw RemoteStorageClientError.requestFailed(http.statusCode, "远程读取失败")
        }
        guard response.expectedContentLength <= Int64(maximumBytes) else { throw RemoteStorageClientError.downloadTooLarge(maximumBytes) }
        var data = Data()
        for try await byte in bytes {
            guard data.count < maximumBytes else { throw RemoteStorageClientError.downloadTooLarge(maximumBytes) }
            if data.count % 32768 == 0 { try Task.checkCancellation() }
            data.append(byte)
        }
        return data
    }
}

/// NSLock protects the Network callback and timeout race; exactly one resume.
final class RemoteFTPReadyGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var finished = false

    func install(_ continuation: CheckedContinuation<Void, Error>) {
        lock.lock(); defer { lock.unlock() }
        self.continuation = continuation
    }

    @discardableResult func finish(_ error: Error?) -> Bool {
        lock.lock()
        guard !finished, let continuation else { lock.unlock(); return false }
        finished = true
        self.continuation = nil
        lock.unlock()
        if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        return true
    }
}

enum RemoteFTPReply {
    static func consume(_ buffer: inout Data) throws -> String? {
        let separator = Data([13, 10])
        guard let firstEnd = buffer.range(of: separator) else { return nil }
        let first = String(decoding: buffer[..<firstEnd.lowerBound], as: UTF8.self)
        guard first.count >= 4, Int(first.prefix(3)) != nil else { throw RemoteStorageClientError.malformedResponse }
        let marker = first[first.index(first.startIndex, offsetBy: 3)]
        var end = firstEnd.upperBound
        if marker == "-" {
            let closing = String(first.prefix(3)) + " "
            while true {
                guard let lineEnd = buffer.range(of: separator, in: end..<buffer.endIndex) else { return nil }
                let line = String(decoding: buffer[end..<lineEnd.lowerBound], as: UTF8.self)
                end = lineEnd.upperBound
                if line.hasPrefix(closing) { break }
            }
        } else if marker != " " { throw RemoteStorageClientError.malformedResponse }
        let reply = String(decoding: buffer[..<end], as: UTF8.self)
        buffer = Data(buffer[end...])
        return reply
    }
}

/// Passive reply parsing is kept independent of Network.framework so malformed
/// delimiter/parenthesis layouts fail instead of creating invalid String ranges.
enum RemoteFTPPassivePort {
    private static func payload(_ reply: String) throws -> Substring {
        guard let start = reply.firstIndex(of: "("), let end = reply.firstIndex(of: ")"), start < end else {
            throw RemoteStorageClientError.malformedResponse
        }
        return reply[reply.index(after: start)..<end]
    }
    static func extended(_ reply: String) throws -> UInt16 {
        let value = try payload(reply)
        guard reply.hasPrefix("229"), let delimiter = value.first else { throw RemoteStorageClientError.malformedResponse }
        let fields = value.split(separator: delimiter, omittingEmptySubsequences: false)
        guard fields.count == 5, fields.prefix(3).allSatisfy({ $0.isEmpty }), fields[4].isEmpty,
              let port = UInt16(fields[3]), port > 0 else { throw RemoteStorageClientError.malformedResponse }
        return port
    }
    static func classic(_ reply: String) throws -> UInt16 {
        let fields = try payload(reply).split(separator: ",", omittingEmptySubsequences: false)
        let values = fields.compactMap { UInt16($0.trimmingCharacters(in: .whitespaces)) }
        guard reply.hasPrefix("227"), fields.count == 6, values.count == 6,
              values.allSatisfy({ $0 <= 255 }), values[4] + values[5] > 0 else { throw RemoteStorageClientError.malformedResponse }
        return values[4] * 256 + values[5]
    }
}

enum RemoteFTPListing {
    static func parse(_ text: String, base: String, machine: Bool) throws -> [RemoteSFTPEntry] {
        try text.split(whereSeparator: \.isNewline).compactMap { raw in
            let line = String(raw)
            var name: String
            var directory: Bool
            var size: UInt64?
            if machine {
                guard let space = line.firstIndex(of: " ") else { throw RemoteStorageClientError.malformedResponse }
                let facts = line[..<space].split(separator: ";").reduce(into: [String: String]()) { result, field in
                    let pair = field.split(separator: "=", maxSplits: 1)
                    if pair.count == 2 { result[String(pair[0]).lowercased()] = String(pair[1]) }
                }
                let type = facts["type"]?.lowercased()
                if type == "cdir" || type == "pdir" { return nil }
                guard type == "file" || type == "dir" else { throw RemoteStorageClientError.malformedResponse }
                name = String(line[line.index(after: space)...])
                directory = type == "dir"
                size = facts["size"].flatMap(UInt64.init)
            } else {
                if line.hasPrefix("total ") { return nil }
                // Unix LIST; unknown/DOS layouts fail visibly instead of an empty folder.
                let fields = line.split(maxSplits: 8, whereSeparator: \.isWhitespace)
                guard fields.count == 9, let kind = fields[0].first, kind == "d" || kind == "-" || kind == "l" else {
                    throw RemoteStorageClientError.invalidConfiguration("FTP LIST 格式不受支持；请启用 MLSD")
                }
                if kind == "l" { return nil } // no traversal through unknown symlink targets
                name = String(fields[8]); directory = kind == "d"; size = UInt64(fields[4])
            }
            guard name != ".", name != "..", !name.isEmpty, !name.contains("/"), !name.contains("\\") else { return nil }
            return RemoteSFTPEntry(path: (base == "/" ? "" : base) + "/" + name, name: name, isDirectory: directory, size: size, modifiedAt: nil, permissions: nil)
        }
    }
}

/// DAV properties are scoped to successful propstat blocks. Missing/failed
/// responses cannot masquerade as empty directories. XML entities are decoded
/// by XMLParser; external entities are never resolved.
enum RemoteDAVListing {
    private final class Delegate: NSObject, XMLParserDelegate {
        struct Item {
            var href = ""
            var size: UInt64?
            var modified: Date?
            var directory = false
            var hasResourceType = false
        }
        var entries: [Item] = []
        var item = Item()
        var properties = Item()
        var text = ""
        var propStatus = ""
        var responseStatus = ""
        var inPropstat = false
        var validRoot = false
        var failed = false
        var hasProperties = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name.split(separator: ":").last.map(String.init) ?? name {
            case "multistatus": validRoot = true
            case "response": item = Item(); responseStatus = ""; hasProperties = false
            case "propstat": properties = Item(); propStatus = ""; inPropstat = true
            case "resourcetype": properties.hasResourceType = true
            case "collection": properties.directory = true
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            switch name.split(separator: ":").last.map(String.init) ?? name {
            case "href": item.href = value
            case "status": if inPropstat { propStatus = value } else { responseStatus = value }
            case "getcontentlength": properties.size = UInt64(value)
            case "getlastmodified":
                let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                properties.modified = formatter.date(from: value)
            case "propstat":
                if propStatus.split(separator: " ").dropFirst().first == "200" {
                    hasProperties = true
                    item.hasResourceType = item.hasResourceType || properties.hasResourceType
                    item.directory = item.directory || properties.directory
                    item.size = properties.size ?? item.size
                    item.modified = properties.modified ?? item.modified
                }
                inPropstat = false
            case "response":
                if !responseStatus.isEmpty && responseStatus.split(separator: " ").dropFirst().first != "200" { failed = true }
                if !hasProperties || !item.hasResourceType { failed = true }
                entries.append(item)
            default: break
            }
            text = ""
        }
    }
    private static func effectivePort(_ url: URL) -> Int? {
        url.port ?? (url.scheme?.lowercased() == "https" ? 443 : 80)
    }

    static func parse(_ data: Data, baseURL: URL) throws -> [RemoteSFTPEntry] {
        let delegate = Delegate(); let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.validRoot, !delegate.failed, !delegate.entries.isEmpty else { throw RemoteStorageClientError.malformedResponse }
        let base = baseURL.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return try delegate.entries.compactMap { item in
            guard !item.href.isEmpty, let url = URL(string: item.href, relativeTo: baseURL)?.absoluteURL,
                  url.host?.lowercased() == baseURL.host?.lowercased(),
                  effectivePort(url) == effectivePort(baseURL), url.scheme?.lowercased() == baseURL.scheme?.lowercased(),
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw RemoteStorageClientError.malformedResponse }
            let path = url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if path == base { return nil }
            let parent = path.split(separator: "/", omittingEmptySubsequences: false).dropLast().joined(separator: "/")
            guard parent == base, !url.lastPathComponent.isEmpty else { throw RemoteStorageClientError.malformedResponse }
            return RemoteSFTPEntry(path: "/" + path, name: url.lastPathComponent, isDirectory: item.directory, size: item.size, modifiedAt: item.modified, permissions: nil)
        }
    }
}

enum RemoteS3Listing {
    struct Page { var entries: [RemoteSFTPEntry]; var nextToken: String? }
    private final class Delegate: NSObject, XMLParserDelegate {
        var key = ""; var prefix = ""; var size: UInt64?; var modified: Date?
        var token = ""; var truncated = false; var validRoot = false; var truncationSeen = false; var invalid = false
        var text = ""; var entries: [RemoteSFTPEntry] = []
        var inPrefix = false
        func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
            text = ""
            switch name {
            case "ListBucketResult": validRoot = true
            case "Contents": key = ""; size = nil; modified = nil
            case "CommonPrefixes": inPrefix = true; prefix = ""
            default: break
            }
        }
        func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
        func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
            switch name {
            case "Key": key = text
            case "Prefix": if inPrefix { prefix = text }
            case "Size": size = UInt64(text)
            case "LastModified": modified = ISO8601DateFormatter().date(from: text)
            case "NextContinuationToken": token = text
            case "IsTruncated":
                let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
                truncationSeen = true; truncated = value == "true"
                if value != "true" && value != "false" { invalid = true }
            case "Contents": entries.append(.init(path: "/" + key, name: (key as NSString).lastPathComponent, isDirectory: key.hasSuffix("/"), size: size, modifiedAt: modified, permissions: nil))
            case "CommonPrefixes":
                entries.append(.init(path: "/" + prefix, name: (prefix as NSString).lastPathComponent, isDirectory: true, size: nil, modifiedAt: nil, permissions: nil)); inPrefix = false
            default: break
            }
            text = ""
        }
    }
    static func parse(_ data: Data, prefix: String) throws -> Page {
        let delegate = Delegate(); let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true; parser.shouldResolveExternalEntities = false; parser.delegate = delegate
        guard parser.parse(), delegate.validRoot, delegate.truncationSeen, !delegate.invalid, !delegate.truncated || !delegate.token.isEmpty else { throw RemoteStorageClientError.malformedResponse }
        var seen = Set<String>()
        let entries = try delegate.entries.filter { entry in
            let key = String(entry.path.dropFirst())
            guard key.hasPrefix(prefix) else { throw RemoteStorageClientError.malformedResponse }
            if key == prefix { return false } // directory marker for this page
            var child = String(key.dropFirst(prefix.count))
            if entry.isDirectory && child.hasSuffix("/") { child.removeLast() }
            guard !child.isEmpty, !child.contains("/"), !child.contains("\\"), child != ".", child != ".." else {
                throw RemoteStorageClientError.malformedResponse
            }
            return seen.insert(entry.path).inserted
        }
        return Page(entries: entries, nextToken: delegate.truncated ? delegate.token : nil)
    }
}
