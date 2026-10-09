import Foundation
import CoreFoundation

struct MailAccount: Codable, Identifiable, Equatable {
    var id = UUID()
    var name = ""
    var address = ""
    var username = ""
    var imapHost = ""
    var imapPort = 993
    var smtpHost = ""
    var smtpPort = 465
    var smtpUsername = ""
    var agentEnabled = true
    var title: String { name.isEmpty ? address : name }
    var imapLogin: String { username.isEmpty ? address : username }
    var smtpLogin: String { smtpUsername.isEmpty ? imapLogin : smtpUsername }

    func validate() throws {
        guard MailCodec.validAddress(address), [imapLogin, smtpLogin].allSatisfy(MailCodec.safeLine),
              !imapLogin.isEmpty, !smtpLogin.isEmpty,
              MailCodec.validHost(imapHost), MailCodec.validHost(smtpHost),
              (1...65535).contains(imapPort), (1...65535).contains(smtpPort) else {
            throw MailError.message("请检查邮箱地址、服务器、端口和登录用户名。")
        }
        guard imapPort != 143, smtpPort != 25, smtpPort != 587 else {
            throw MailError.message("请选择直接 SSL/TLS 端口，通常 IMAP 为 993、SMTP 为 465；此连接器不使用 STARTTLS 或明文连接。")
        }
    }
}

struct MailCredentials: Codable {
    var imapPassword: String
    var smtpPassword: String
}

enum MailError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let value) = self { return value }; return nil }
}

enum MailCodec {
    static func safeLine(_ value: String) -> Bool {
        !value.unicodeScalars.contains { $0.value < 32 || $0.value == 127 }
    }
    static func validHost(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 253 && value.utf8.allSatisfy {
            (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 46
        } && !value.hasPrefix(".") && !value.hasSuffix(".")
    }
    static func validAddress(_ value: String) -> Bool {
        let parts = value.split(separator: "@", omittingEmptySubsequences: false)
        let allowed = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.!#$%&'*+-/=?^_`{|}~"
        return parts.count == 2 && !parts[0].isEmpty && parts[0].count <= 64 && value.count <= 254
            && parts[0].allSatisfy { allowed.contains($0) } && !parts[0].hasPrefix(".")
            && !parts[0].hasSuffix(".") && !parts[0].contains("..") && validHost(String(parts[1]))
    }
    static func quoted(_ value: String) throws -> String {
        guard safeLine(value) else { throw MailError.message("邮箱参数包含无效控制字符。") }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    static func wrappedBase64(_ data: Data) -> String {
        let s = Array(data.base64EncodedString())
        return stride(from: 0, to: s.count, by: 76).map { String(s[$0..<min($0 + 76, s.count)]) }.joined(separator: "\r\n")
    }
    static func message(from: String, recipients: [String], subject: String, body: String) throws -> Data {
        guard validAddress(from), !recipients.isEmpty, recipients.count <= 20, recipients.allSatisfy(validAddress),
              safeLine(subject), subject.utf8.count <= 500, body.utf8.count <= 500_000 else {
            throw MailError.message("邮件参数无效：收件人最多 20 个，主题最多 500 字节，正文最多 500 KB。")
        }
        // RFC 2047 encoded words must stay under 75 characters, including delimiters.
        var chunks: [String] = []; var chunk = ""
        for c in subject.unicodeScalars {
            if (chunk + String(c)).utf8.count > 42 && !chunk.isEmpty { chunks.append(chunk); chunk = "" }
            chunk.append(contentsOf: String(c))
        }
        if !chunk.isEmpty { chunks.append(chunk) }
        let encodedSubject = chunks.map { "=?UTF-8?B?\(Data($0.utf8).base64EncodedString())?=" }.joined(separator: "\r\n ")
        let date = DateFormatter(); date.locale = Locale(identifier: "en_US_POSIX")
        date.dateFormat = "EEE, dd MMM yyyy HH:mm:ss Z"
        let headers = ["From: <\(from)>", "To: " + recipients.map { "<\($0)>" }.joined(separator: ",\r\n "),
                       "Subject: \(encodedSubject)", "Date: \(date.string(from: Date()))",
                       "Message-ID: <\(UUID().uuidString)@\(from.split(separator: "@").last!)>",
                       "MIME-Version: 1.0", "Content-Type: text/plain; charset=UTF-8", "Content-Transfer-Encoding: base64"]
        return Data((headers.joined(separator: "\r\n") + "\r\n\r\n" + wrappedBase64(Data(body.utf8)) + "\r\n").utf8)
    }
    static func headers(_ source: String) -> [String: String] {
        let unfolded = source.replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\n[ \t]+", with: " ", options: .regularExpression)
        var result: [String: String] = [:]
        for line in unfolded.components(separatedBy: "\n") {
            if line.isEmpty { break }
            guard let colon = line.firstIndex(of: ":") else { continue }
            result[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
    static func decodeText(_ data: Data, charset: String = "utf-8") -> String {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        let encoding: String.Encoding = cfEncoding == kCFStringEncodingInvalidId ? .utf8
            : String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(cfEncoding))
        return String(data: data, encoding: encoding) ?? String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
    }
    static func quotedPrintable(_ source: String, header: Bool = false) -> Data {
        let bytes = Array(source.replacingOccurrences(of: "=\r\n", with: "").replacingOccurrences(of: "=\n", with: "").utf8)
        var out = Data(); var i = 0
        while i < bytes.count {
            if bytes[i] == 61, i + 2 < bytes.count,
               let byte = UInt8(String(decoding: bytes[(i+1)...(i+2)], as: UTF8.self), radix: 16) {
                out.append(byte); i += 3
            } else { out.append(header && bytes[i] == 95 ? 32 : bytes[i]); i += 1 }
        }
        return out
    }
    static func decodedHeader(_ value: String) -> String {
        let source = value.replacingOccurrences(of: "(?<=\\?=)[ \t\r\n]+(?==\\?)", with: "", options: .regularExpression)
        guard let regex = try? NSRegularExpression(pattern: "=\\?([^?]+)\\?([BbQq])\\?([^?]*)\\?=") else { return source }
        var result = source
        for match in regex.matches(in: source, range: NSRange(source.startIndex..., in: source)).reversed() {
            let ns = source as NSString
            let charset = ns.substring(with: match.range(at: 1)), mode = ns.substring(with: match.range(at: 2))
            let text = ns.substring(with: match.range(at: 3))
            let data = mode.lowercased() == "b" ? Data(base64Encoded: text) : quotedPrintable(text, header: true)
            if let data, let range = Range(match.range, in: result) { result.replaceSubrange(range, with: decodeText(data, charset: charset)) }
        }
        return result
    }
    static func parameter(_ name: String, in value: String) -> String? {
        for part in value.components(separatedBy: ";").dropFirst() {
            let pair = part.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            if pair.count == 2 && pair[0].lowercased() == name { return pair[1].trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
        }
        return nil
    }
    static func readableBody(_ raw: String, depth: Int = 0) -> String {
        guard depth < 8 else { return "[邮件嵌套层数过多]" }
        let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
        guard let separator = normalized.range(of: "\n\n") else { return "" }
        let h = headers(String(normalized[..<separator.lowerBound]))
        let type = h["content-type"] ?? "text/plain"
        let body = String(normalized[separator.upperBound...])
        if (h["content-disposition"] ?? "").lowercased().hasPrefix("attachment") { return "" }
        if type.lowercased().hasPrefix("multipart/"), let boundary = parameter("boundary", in: type) {
            return body.components(separatedBy: "--" + boundary).dropFirst().prefix(40)
                .filter { !$0.hasPrefix("--") }
                .map { readableBody($0.trimmingCharacters(in: .newlines), depth: depth + 1) }
                .filter { !$0.isEmpty }.joined(separator: "\n")
        }
        guard type.lowercased().hasPrefix("text/") else { return "[非文本媒体，未下载附件]" }
        let transfer = (h["content-transfer-encoding"] ?? "").lowercased()
        let data: Data
        if transfer == "base64" { data = Data(base64Encoded: body.filter { !$0.isWhitespace }) ?? Data() }
        else if transfer == "quoted-printable" { data = quotedPrintable(body) }
        else { data = Data(body.utf8) }
        var text = decodeText(data, charset: parameter("charset", in: type) ?? "utf-8")
        if type.lowercased().hasPrefix("text/html") {
            text = text.replacingOccurrences(of: "(?is)<(script|style)[^>]*>.*?</\\1>", with: "", options: .regularExpression)
                .replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
        }
        return String(text.prefix(50_000))
    }
}
