import Foundation

/// Experimental web protocol, pinned against basketikun/chatgpt2api
/// 92dd80e91543157d36a4ddad60e765c5293760e9. This is not the Codex Responses API.
/// Keep wire parsing independent of UIKit/networking so fixtures exercise production code.
enum ChatGPTWebError: LocalizedError {
    case authenticationExpired
    case browserVerificationRequired
    case unsupportedAttachment
    case unsupportedTools
    case malformedResponse
    case incompleteResponse
    case rewrittenResponse
    case proofBudgetExceeded
    case rejected(Int)

    var errorDescription: String? {
        switch self {
        case .authenticationExpired:
            return "ChatGPT 网页登录已失效，请在服务商详情重新登录。"
        case .browserVerificationRequired:
            return "ChatGPT 网页服务要求浏览器验证。请打开网页登录完成验证后重试；实验直连仍可能被网页服务拒绝。"
        case .unsupportedAttachment:
            return "ChatGPT 网页实验直连目前仅接入文字对话，请移除附件或选择其他服务商。"
        case .unsupportedTools:
            return "ChatGPT 网页实验直连仅提供文字对话；本地工具与子代理请使用其他服务商。"
        case .malformedResponse:
            return "ChatGPT 网页响应格式发生变化，实验直连需要更新。"
        case .incompleteResponse:
            return "ChatGPT 网页回复未完整结束，请重试。"
        case .rewrittenResponse:
            return "ChatGPT 网页改写了已输出的内容，已停止本次回复以避免重复文本。"
        case .proofBudgetExceeded:
            return "ChatGPT 网页验证超过计算时限，请稍后重试。"
        case .rejected(let status):
            return "ChatGPT 网页服务拒绝了请求（HTTP \(status)）。"
        }
    }
}

enum ChatGPTWebProtocol {
    static func message(role: String, text: String, id: String = UUID().uuidString.lowercased()) -> [String: Any] {
        ["id": id, "author": ["role": role], "content": ["content_type": "text", "parts": [text]]]
    }

    static func payload(messages: [[String: Any]], model: String, timezone: TimeZone = .current) -> [String: Any] {
        [
            "action": "next", "messages": messages, "model": model,
            "parent_message_id": UUID().uuidString.lowercased(),
            "conversation_mode": ["kind": "primary_assistant"],
            "conversation_origin": NSNull(), "force_paragen": false,
            "force_paragen_model_slug": "", "force_rate_limit": false,
            "force_use_sse": true, "history_and_training_disabled": true,
            "reset_rate_limits": false, "suggestions": [],
            "supported_encodings": [], "system_hints": [],
            "timezone": timezone.identifier, "timezone_offset_min": -(timezone.secondsFromGMT() / 60),
            "variant_purpose": "comparison_implicit", "websocket_request_id": UUID().uuidString.lowercased()
        ]
    }

    static func checkHTTP(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw ChatGPTWebError.malformedResponse }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ChatGPTWebError.authenticationExpired
        case 403: throw ChatGPTWebError.browserVerificationRequired
        default: throw ChatGPTWebError.rejected(http.statusCode)
        }
    }

    /// Token/error bodies are intentionally never interpolated into errors or logs.
    static func object(from data: Data) throws -> [String: Any] {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["error"] == nil || object["error"] is NSNull else {
            throw ChatGPTWebError.malformedResponse
        }
        return object
    }

    static func requirementsConfig(userAgent: String, html: String, deviceId: String) -> [Any] {
        let script = capture("<script[^>]*src=[\"']([^\"']+)", in: html)
            ?? "https://chatgpt.com/backend-api/sentinel/sdk.js"
        let build = capture("<html[^>]*data-build=[\"']([^\"']*)", in: html) ?? ""
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE MMM dd yyyy HH:mm:ss 'GMT+0000 (Coordinated Universal Time)'"
        let uptime = ProcessInfo.processInfo.systemUptime * 1000
        // The wire format is positional. Values describe this client; no desktop TLS impersonation.
        return [0, formatter.string(from: Date()), 4294705152 as UInt64, 1,
                userAgent, script, build, "en-US", "en-US,en", Double.random(in: 0..<1),
                "onLine−true", "location", "navigator", uptime, deviceId, "",
                ProcessInfo.processInfo.activeProcessorCount, Date().timeIntervalSince1970 * 1000 - uptime,
                0, 0, 0, 0, 0, 0, 0]
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[range])
    }

    static func requirementsToken(config: [Any]) throws -> String {
        "gAAAAAC" + (try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes])).base64EncodedString()
    }

    /// Bounded CPU work runs away from the UI executor. Cancellation propagates into the solver.
    static func proofToken(seed: String, difficulty: String, config: [Any]) async throws -> String {
        let serialized = try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes])
        let task = Task.detached(priority: .utility) {
            try solveProof(seed: seed, difficulty: difficulty, serializedConfig: serialized)
        }
        return try await withTaskCancellationHandler(operation: {
            try await task.value
        }, onCancel: { task.cancel() })
    }

    static func solveProof(seed: String, difficulty: String, serializedConfig: Data,
                           maxAttempts: Int = 100_000, timeBudget: TimeInterval = 3) throws -> String {
        guard !seed.isEmpty, seed.utf8.count < 4096, !difficulty.isEmpty,
              difficulty.count <= 128, difficulty.count.isMultiple(of: 2),
              var config = try JSONSerialization.jsonObject(with: serializedConfig) as? [Any],
              config.count >= 10 else { throw ChatGPTWebError.malformedResponse }
        var target: [UInt8] = []
        var cursor = difficulty.startIndex
        while cursor < difficulty.endIndex {
            let end = difficulty.index(cursor, offsetBy: 2)
            guard let byte = UInt8(difficulty[cursor..<end], radix: 16) else { throw ChatGPTWebError.malformedResponse }
            target.append(byte)
            cursor = end
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeBudget)
        for attempt in 0..<max(0, maxAttempts) {
            if attempt.isMultiple(of: 64) {
                try Task.checkCancellation()
                guard ProcessInfo.processInfo.systemUptime < deadline else { throw ChatGPTWebError.proofBudgetExceeded }
            }
            config[3] = attempt
            config[9] = attempt >> 1
            let encoded = try JSONSerialization.data(withJSONObject: config, options: [.withoutEscapingSlashes]).base64EncodedString()
            let digest = sha3_512(Array((seed + encoded).utf8))
            let prefix = Array(digest.prefix(target.count))
            if prefix == target || prefix.lexicographicallyPrecedes(target) { return "gAAAAAB" + encoded }
        }
        throw ChatGPTWebError.proofBudgetExceeded
    }

    /// FIPS 202 SHA3-512 (72-byte rate, domain separator 0x06). No native dependency
    /// or APIs newer than iOS 16. Exposed internally for published digest-vector tests.
    static func sha3_512(_ input: [UInt8]) -> [UInt8] {
        let constants: [UInt64] = [
            0x0000000000000001, 0x0000000000008082, 0x800000000000808a, 0x8000000080008000,
            0x000000000000808b, 0x0000000080000001, 0x8000000080008081, 0x8000000000008009,
            0x000000000000008a, 0x0000000000000088, 0x0000000080008009, 0x000000008000000a,
            0x000000008000808b, 0x800000000000008b, 0x8000000000008089, 0x8000000000008003,
            0x8000000000008002, 0x8000000000000080, 0x000000000000800a, 0x800000008000000a,
            0x8000000080008081, 0x8000000000008080, 0x0000000080000001, 0x8000000080008008
        ]
        let rotation: [Int] = [0, 1, 62, 28, 27, 36, 44, 6, 55, 20, 3, 10, 43, 25, 39,
                               41, 45, 15, 21, 8, 18, 2, 61, 56, 14]
        func rotate(_ value: UInt64, _ count: Int) -> UInt64 {
            count == 0 ? value : (value << count) | (value >> (64 - count))
        }
        var padded = input
        padded.append(0x06)
        while padded.count % 72 != 0 { padded.append(0) }
        padded[padded.count - 1] |= 0x80
        var state = [UInt64](repeating: 0, count: 25)
        for offset in stride(from: 0, to: padded.count, by: 72) {
            for byte in 0..<72 { state[byte / 8] ^= UInt64(padded[offset + byte]) << ((byte % 8) * 8) }
            for constant in constants {
                var column = [UInt64](repeating: 0, count: 5)
                for x in 0..<5 { for y in 0..<5 { column[x] ^= state[x + 5 * y] } }
                for x in 0..<5 {
                    let delta = column[(x + 4) % 5] ^ rotate(column[(x + 1) % 5], 1)
                    for y in 0..<5 { state[x + 5 * y] ^= delta }
                }
                var rotated = [UInt64](repeating: 0, count: 25)
                for x in 0..<5 {
                    for y in 0..<5 { rotated[y + 5 * ((2 * x + 3 * y) % 5)] = rotate(state[x + 5 * y], rotation[x + 5 * y]) }
                }
                for x in 0..<5 {
                    for y in 0..<5 {
                        state[x + 5 * y] = rotated[x + 5 * y] ^ ((~rotated[(x + 1) % 5 + 5 * y]) & rotated[(x + 2) % 5 + 5 * y])
                    }
                }
                state[0] ^= constant
            }
        }
        return (0..<64).map { UInt8(truncatingIfNeeded: state[$0 / 8] >> (($0 % 8) * 8)) }
    }
}

/// Parses only visible assistant output. Tool commands, hidden messages, and internal
/// analysis channels never become user-visible text, including subsequent patch events.
struct ChatGPTWebStreamParser {
    private(set) var finished = false
    private var currentID = ""
    private var visible = false
    private var rawText = ""
    private var emittedText = ""
    private var hadOutput = false
    private var needsSeparator = false
    private var lastTextPath = ""
    let historyIDs: Set<String>

    init(historyIDs: Set<String> = []) { self.historyIDs = historyIDs }

    mutating func consume(_ payload: String) throws -> String? {
        guard !finished else { return nil }
        if payload == "[DONE]" { finished = true; return nil }
        guard let data = payload.data(using: .utf8),
              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ChatGPTWebError.malformedResponse
        }
        if let error = event["error"], !(error is NSNull) { throw ChatGPTWebError.malformedResponse }
        if event["type"] as? String == "moderation",
           let moderation = event["moderation_response"] as? [String: Any], moderation["blocked"] as? Bool == true {
            throw ChatGPTWebError.rejected(403)
        }
        let value = event["v"] as? [String: Any]
        if let message = (event["message"] ?? value?["message"]) as? [String: Any] {
            return try snapshot(message)
        }
        return try patch(event)
    }

    private mutating func snapshot(_ message: [String: Any]) throws -> String? {
        let identifier = message["id"] as? String ?? ""
        let changed = !identifier.isEmpty && identifier != currentID
        if changed {
            needsSeparator = hadOutput
            currentID = identifier
            rawText = ""
            emittedText = ""
            lastTextPath = ""
        }
        let author = message["author"] as? [String: Any]
        let metadata = message["metadata"] as? [String: Any]
        let recipient = message["recipient"] as? String ?? "all"
        let channel = message["channel"] as? String ?? "final"
        visible = author?["role"] as? String == "assistant"
            && (recipient.isEmpty || recipient == "all")
            && (channel.isEmpty || channel == "final")
            && metadata?["is_visually_hidden_from_conversation"] as? Bool != true
            && !historyIDs.contains(identifier)
        guard visible else { return nil }
        let content = message["content"] as? [String: Any] ?? [:]
        if let parts = content["parts"] as? [Any] {
            rawText = parts.compactMap { $0 as? String }.joined()
        } else { rawText = content["text"] as? String ?? "" }
        return try emit()
    }

    private mutating func patch(_ event: [String: Any]) throws -> String? {
        if let operations = event["v"] as? [[String: Any]] {
            var output = ""
            for operation in operations { output += try patch(operation) ?? "" }
            return output.isEmpty ? nil : output
        }
        let path = event["p"] as? String ?? ""
        if path == "/message", let message = event["v"] as? [String: Any] { return try snapshot(message) }
        // A channel/recipient change must clear eligibility before any later text patch.
        if path == "/message/channel" || path == "/message/recipient" || path == "/message/author/role" {
            let text = event["v"] as? String ?? ""
            if (path.hasSuffix("channel") && text != "final" && !text.isEmpty)
                || (path.hasSuffix("recipient") && text != "all" && !text.isEmpty)
                || (path.hasSuffix("role") && text != "assistant") { visible = false }
            return nil
        }
        if path == "/message/metadata/is_visually_hidden_from_conversation", event["v"] as? Bool == true {
            visible = false
            return nil
        }
        if path == "/message/metadata", let metadata = event["v"] as? [String: Any],
           metadata["is_visually_hidden_from_conversation"] as? Bool == true {
            visible = false
            return nil
        }
        if path == "/message/author", let author = event["v"] as? [String: Any], author["role"] as? String != "assistant" {
            visible = false
            return nil
        }
        guard visible else { return nil }
        let isTextPath = path == "/message/content/parts/0" || path == "/message/content/text"
        if isTextPath { lastTextPath = path }
        guard isTextPath || (path.isEmpty && !lastTextPath.isEmpty) else { return nil }
        guard let text = event["v"] as? String else { return nil }
        let operation = event["o"] as? String ?? "append"
        if operation == "append" { rawText += text }
        else if operation == "replace" { rawText = text }
        else { return nil }
        return try emit()
    }

    private mutating func emit() throws -> String? {
        guard rawText.utf8.count <= 2 * 1024 * 1024 else { throw ChatGPTWebError.malformedResponse }
        // Private-use citation handles are incomplete until their closing marker arrives.
        // Suppress the pending tail rather than streaming half of an internal identifier.
        var text = rawText
        if let start = text.range(of: "\u{e200}", options: .backwards),
           text[start.upperBound...].range(of: "\u{e201}") == nil { text = String(text[..<start.lowerBound]) }
        if let regex = try? NSRegularExpression(pattern: "\u{e200}[^\u{e201}]*\u{e201}") {
            text = regex.stringByReplacingMatches(in: text, range: NSRange(text.startIndex..., in: text), withTemplate: "")
        }
        guard text.hasPrefix(emittedText) else { throw ChatGPTWebError.rewrittenResponse }
        let delta = String(text.dropFirst(emittedText.count))
        guard !delta.isEmpty else { return nil }
        emittedText = text
        hadOutput = true
        let separator = needsSeparator ? "\n\n" : ""
        needsSeparator = false
        return separator + delta
    }
}

/// AsyncBytes.lines implementations may omit empty lines. Web events carry one JSON
/// value per data frame, so recognize a complete value eagerly while still accepting
/// multiline data. Never depend on an empty line to flush a complete event.
struct ChatGPTWebSSEDecoder {
    private var dataLines: [String] = []
    private var byteCount = 0

    mutating func consume(line: String) throws -> String? {
        if line.isEmpty {
            guard !dataLines.isEmpty else { return nil }
            return flush()
        }
        guard line.hasPrefix("data:") else { return nil }
        let raw = line.dropFirst(5)
        let value = raw.hasPrefix(" ") ? String(raw.dropFirst()) : String(raw)
        byteCount += value.utf8.count
        guard byteCount <= 2 * 1024 * 1024 else { throw ChatGPTWebError.malformedResponse }
        dataLines.append(value)
        let joined = dataLines.joined(separator: "\n")
        if joined == "[DONE]" { return flush() }
        if let data = joined.data(using: .utf8), (try? JSONSerialization.jsonObject(with: data)) != nil { return flush() }
        return nil
    }

    mutating func flush() -> String? {
        guard !dataLines.isEmpty else { return nil }
        let value = dataLines.joined(separator: "\n")
        dataLines.removeAll(keepingCapacity: true)
        byteCount = 0
        return value
    }
}
