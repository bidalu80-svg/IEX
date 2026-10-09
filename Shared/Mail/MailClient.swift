import Foundation
@preconcurrency import Network

/// A one-shot continuation protects ready/error/timeout races from double resume.
private final class MailCompletion<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Value, Error>?
    init(_ continuation: CheckedContinuation<Value, Error>) { self.continuation = continuation }
    @discardableResult func finish(_ result: Result<Value, Error>) -> Bool {
        lock.lock(); let current = continuation; continuation = nil; lock.unlock()
        current?.resume(with: result)
        return current != nil
    }
}

/// Only direct TLS connections: system certificate and hostname validation stay enabled.
private actor MailSocket {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "ze.mail.socket")
    private var buffer = Data()
    init(host: String, port: Int) throws {
        guard let value = UInt16(exactly: port), let endpointPort = NWEndpoint.Port(rawValue: value) else {
            throw MailError.message("邮箱端口无效。")
        }
        connection = NWConnection(host: NWEndpoint.Host(host), port: endpointPort, using: .tls)
    }
    nonisolated func close() { connection.cancel() }
    private func operation<T>(_ begin: (MailCompletion<T>) -> Void) async throws -> T {
        try Task.checkCancellation()
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                let once = MailCompletion<T>(continuation)
                queue.asyncAfter(deadline: .now() + 30) { [connection] in
                    if once.finish(.failure(MailError.message("邮箱连接超时，请检查网络和服务器配置。"))) { connection.cancel() }
                }
                begin(once)
            }
        }, onCancel: { self.close() })
    }
    func open() async throws {
        let _: Bool = try await operation { once in
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: once.finish(.success(true))
                case .failed, .cancelled: once.finish(.failure(MailError.message("邮箱 TLS 连接失败，请检查主机、端口和证书。")))
                default: break
                }
            }
            connection.start(queue: queue)
        }
    }
    func send(_ value: String) async throws { try await send(Data(value.utf8)) }
    func send(_ value: Data) async throws {
        let _: Bool = try await operation { once in
            connection.send(content: value, completion: .contentProcessed { error in
                if error != nil { once.finish(.failure(MailError.message("邮箱连接中断。"))) }
                else { once.finish(.success(true)) }
            })
        }
    }
    private func receive() async throws {
        let data: Data = try await operation { once in
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { data, _, _, error in
                if error != nil { once.finish(.failure(MailError.message("读取邮箱响应失败。"))) }
                else if let data, !data.isEmpty { once.finish(.success(data)) }
                else { once.finish(.failure(MailError.message("邮箱服务器已关闭连接。"))) }
            }
        }
        buffer.append(data)
        guard buffer.count <= 2_000_000 else { throw MailError.message("邮箱响应超过大小限制。") }
    }
    func line() async throws -> String {
        let separator = Data([13, 10])
        while buffer.range(of: separator) == nil {
            guard buffer.count < 1_000_000 else { throw MailError.message("邮箱响应行过长。") }
            try await receive()
        }
        let range = buffer.range(of: separator)!
        let value = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
        buffer = Data(buffer[range.upperBound...])
        return value
    }
    func bytes(_ count: Int) async throws -> Data {
        guard (0...524_288).contains(count) else { throw MailError.message("邮件内容超过读取限制。") }
        while buffer.count < count { try await receive() }
        let result = Data(buffer.prefix(count)); buffer = Data(buffer.dropFirst(count)); return result
    }
}

private actor MailIMAPSession {
    let socket: MailSocket
    private var sequence = 0
    init(account: MailAccount) throws { socket = try MailSocket(host: account.imapHost, port: account.imapPort) }
    nonisolated func close() { socket.close() }
    func login(account: MailAccount, password: String) async throws {
        try await socket.open()
        let greeting = try await socket.line()
        guard greeting.uppercased().hasPrefix("* OK") else { throw MailError.message("IMAP 服务器问候无效。") }
        _ = try await command("LOGIN \(MailCodec.quoted(account.imapLogin)) \(MailCodec.quoted(password))")
    }
    func command(_ command: String) async throws -> (lines: [String], literals: [Data]) {
        sequence += 1; let tag = "ZE\(sequence)"
        try await socket.send("\(tag) \(command)\r\n")
        var lines: [String] = []; var literals: [Data] = []; var total = 0
        for _ in 0..<2000 {
            let line = try await socket.line(); total += line.utf8.count
            guard total <= 2_000_000 else { throw MailError.message("IMAP 响应超过限制。") }
            if line.hasPrefix(tag + " ") {
                guard line.uppercased().hasPrefix(tag + " OK") else {
                    throw MailError.message("IMAP 操作被拒绝，请检查授权码并启用 IMAP 服务。")
                }
                return (lines, literals)
            }
            if line.uppercased().hasPrefix("* BYE") || line.hasPrefix("+") {
                throw MailError.message("IMAP 会话已结束或认证方式不匹配。")
            }
            lines.append(line)
            if line.hasSuffix("}"), let start = line.lastIndex(of: "{"), let count = Int(line[line.index(after: start)..<line.index(before: line.endIndex)]) {
                let data = try await socket.bytes(count); total += data.count; literals.append(data)
            }
        }
        throw MailError.message("IMAP 响应条目过多。")
    }
    func inbox() async throws -> String {
        let response = try await command("EXAMINE INBOX")
        for line in response.lines {
            if let start = line.range(of: "[UIDVALIDITY ", options: .caseInsensitive) {
                let rest = line[start.upperBound...]
                if let end = rest.firstIndex(of: "]") { return String(rest[..<end]) }
            }
        }
        throw MailError.message("邮箱未返回 UIDVALIDITY，请检查 IMAP 服务器。")
    }
}

/// Plain-text email tools, no credential strings in outputs or logs.
enum MailClient {
    static func test(account: MailAccount, credentials: MailCredentials) async throws {
        try account.validate()
        let imap = try MailIMAPSession(account: account); defer { imap.close() }
        try await imap.login(account: account, password: credentials.imapPassword)
        _ = try await imap.inbox()
        let smtp = try MailSocket(host: account.smtpHost, port: account.smtpPort); defer { smtp.close() }
        try await smtpLogin(smtp, account: account, password: credentials.smtpPassword)
    }
    static func list(account: MailAccount, credentials: MailCredentials, limit: Int, beforeUID: UInt32? = nil) async throws -> [[String: String]] {
        let session = try MailIMAPSession(account: account); defer { session.close() }
        try await session.login(account: account, password: credentials.imapPassword)
        let validity = try await session.inbox()
        let response = try await session.command("UID SEARCH ALL")
        let ids = MailCodec.searchUIDs(response.lines, before: beforeUID, limit: limit)
        var result: [[String: String]] = []
        for uid in ids {
            try Task.checkCancellation()
            let message = try await session.command("UID FETCH \(uid) (BODY.PEEK[HEADER.FIELDS (FROM TO SUBJECT DATE)]<0.32768>)")
            guard let data = message.literals.first else { continue }
            let h = MailCodec.headers(String(decoding: data, as: UTF8.self))
            result.append(["uid": String(uid), "uid_validity": validity, "subject": MailCodec.decodedHeader(h["subject"] ?? ""),
                           "from": MailCodec.decodedHeader(h["from"] ?? ""), "date": h["date"] ?? ""])
        }
        return result
    }
    static func read(account: MailAccount, credentials: MailCredentials, uid: UInt32, validity: String) async throws -> [String: String] {
        let session = try MailIMAPSession(account: account); defer { session.close() }
        try await session.login(account: account, password: credentials.imapPassword)
        let current = try await session.inbox()
        guard current == validity else { throw MailError.message("邮箱索引已更新，请重新列出邮件后再读取。") }
        let response = try await session.command("UID FETCH \(uid) (BODY.PEEK[]<0.262144>)")
        guard let data = response.literals.first else { throw MailError.message("邮件不存在或已移走。") }
        let raw = String(decoding: data, as: UTF8.self), h = MailCodec.headers(raw)
        return ["uid": String(uid), "uid_validity": current, "from": MailCodec.decodedHeader(h["from"] ?? ""),
                "to": MailCodec.decodedHeader(h["to"] ?? ""), "subject": MailCodec.decodedHeader(h["subject"] ?? ""),
                "date": h["date"] ?? "", "body": MailCodec.readableBody(raw),
                "notice": data.count >= 262144 ? "原始邮件超过读取上限，内容可能截断；附件未提取。" : "仅返回文本；附件未提取。"]
    }
    private static func smtpReply(_ socket: MailSocket, expected: [Int]) async throws -> [String] {
        var lines: [String] = []; var firstCode: Int?
        for _ in 0..<100 {
            let line = try await socket.line()
            guard line.utf8.count < 16_384, let code = Int(line.prefix(3)), line.count >= 4,
                  firstCode == nil || code == firstCode else { throw MailError.message("SMTP 响应格式错误。") }
            firstCode = code; lines.append(line)
            let separator = line[line.index(line.startIndex, offsetBy: 3)]
            if separator == " " {
                guard expected.contains(code) else { throw MailError.message("SMTP 操作被拒绝（\(code)），请检查发信配置、授权码或收件人。") }
                return lines
            }
            guard separator == "-" else { throw MailError.message("SMTP 响应格式错误。") }
        }
        throw MailError.message("SMTP 响应条目过多。")
    }
    private static func smtpLogin(_ socket: MailSocket, account: MailAccount, password: String) async throws {
        try await socket.open(); _ = try await smtpReply(socket, expected: [220])
        try await socket.send("EHLO ze.local\r\n")
        let capabilities = try await smtpReply(socket, expected: [250])
        let auth = capabilities.filter { $0.uppercased().dropFirst(4).hasPrefix("AUTH") }.joined(separator: " ").uppercased()
        if auth.contains("PLAIN") {
            let value = Data(("\0" + account.smtpLogin + "\0" + password).utf8).base64EncodedString()
            try await socket.send("AUTH PLAIN\r\n"); _ = try await smtpReply(socket, expected: [334])
            try await socket.send(value + "\r\n"); _ = try await smtpReply(socket, expected: [235])
        } else if auth.contains("LOGIN") {
            try await socket.send("AUTH LOGIN\r\n"); _ = try await smtpReply(socket, expected: [334])
            try await socket.send(Data(account.smtpLogin.utf8).base64EncodedString() + "\r\n"); _ = try await smtpReply(socket, expected: [334])
            try await socket.send(Data(password.utf8).base64EncodedString() + "\r\n"); _ = try await smtpReply(socket, expected: [235])
        } else { throw MailError.message("服务器未提供密码或授权码认证；请选择启用此方式的邮箱。") }
    }
    static func send(account: MailAccount, credentials: MailCredentials, recipients: [String], subject: String, body: String) async throws {
        let data = try MailCodec.message(from: account.address, recipients: recipients, subject: subject, body: body)
        let socket = try MailSocket(host: account.smtpHost, port: account.smtpPort); defer { socket.close() }
        try await smtpLogin(socket, account: account, password: credentials.smtpPassword)
        try await socket.send("MAIL FROM:<\(account.address)>\r\n"); _ = try await smtpReply(socket, expected: [250])
        for address in recipients {
            try await socket.send("RCPT TO:<\(address)>\r\n"); _ = try await smtpReply(socket, expected: [250, 251])
        }
        try Task.checkCancellation()
        try await socket.send("DATA\r\n"); _ = try await smtpReply(socket, expected: [354])
        do {
            // Body is base64, so no payload line can start with a dot.
            try await socket.send(data + Data(".\r\n".utf8))
            _ = try await smtpReply(socket, expected: [250])
        } catch {
            throw MailError.message("提交邮件后未确认服务器接收结果。请先核查收件情况，避免自动重发产生重复邮件。")
        }
        // Success means SMTP accepted; it is not a delivery/read receipt.
    }
}
