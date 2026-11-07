#!/usr/bin/env python3
"""Compile production web protocol/transport and exercise isolated wire fixtures.

No credentials, vendor traffic, or copied parser/crypto implementation. The small
app-type stubs are deliberately outside production; the full app build validates
the real LLM/Agent integration separately.
"""
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCES = [ROOT / "Providers/OpenAI/ChatGPTWeb" / name for name in
           ("ChatGPTWebProtocol.swift", "ChatGPTWebChallenge.swift", "ChatGPTWebProvider.swift")]

STUBS = r'''
import Foundation
struct ModelModality { static let textOnly = ModelModality() }
struct LLMModel {
    let id: String; let displayName: String; let provider: String
    var modalityOverride: ModelModality?; var maxOutputTokens: Int? = nil; var supportsReasoning: Bool?
}
struct LLMMessage {
    enum Role: String { case user, assistant }
    let role: Role; let content: String; var images: [Data] = []; var audios: [Data] = []
}
struct LLMUsage {}
struct LLMResponse { let text: String; let stopReason: String?; let usage: LLMUsage? }
enum LLMStreamChunk { case started, text(String), usage(LLMUsage), finished(stopReason: String?) }
protocol LLMProvider {
    var name: String { get }; var model: LLMModel { get set }
    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse
    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error>
}
enum ThinkingLevel { case off }
struct AgentToolDefinition {}
enum AgentContentPart { case text(String), imageData(Data), toolUse, toolResult }
struct AgentMessage { enum Role { case user, assistant }; let role: Role; let parts: [AgentContentPart] }
enum AgentBlockStart { case text }
enum AgentStopReason { case endTurn }
enum AgentStreamEvent { case contentBlockStart(AgentBlockStart), textDelta(String), usage(LLMUsage), done(stopReason: AgentStopReason) }
protocol AgentProvider {
    var name: String { get }; var model: LLMModel { get }; var defaultMaxTokens: Int { get }
    var providerInstanceId: String? { get }; var supportsNativeTools: Bool { get }
    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int,
                                  thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error>
}
enum ResponseIdleTimeoutSetting { static func seconds(forInstanceId: String?) -> Int { 10 } }
'''

HARNESS = r'''
import Foundation

func encoded(_ object: Any) throws -> String { String(data: try JSONSerialization.data(withJSONObject: object), encoding: .utf8)! }
func snapshot(_ id: String, _ text: String, role: String = "assistant", channel: String = "final", recipient: String = "all") -> [String: Any] {
    ["message": ["id": id, "author": ["role": role], "channel": channel, "recipient": recipient,
                 "content": ["content_type": "text", "parts": [text]]]]
}
func expectError(_ operation: () throws -> Void, _ predicate: (Error) -> Bool) {
    do { try operation(); fatalError("Expected an error") } catch { precondition(predicate(error), "Unexpected error: \(error)") }
}
func require(_ condition: Bool) { precondition(condition) }
func isMalformed(_ error: Error) -> Bool { if case ChatGPTWebError.malformedResponse = error { return true }; return false }

final class FixtureProtocol: URLProtocol {
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var streamMode = "normal"
    static func body(_ request: URLRequest) -> Data {
        if let data = request.httpBody { return data }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open(); defer { stream.close() }
        var data = Data(); var buffer = [UInt8](repeating: 0, count: 1024)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            precondition(count >= 0)
            if count == 0 { break }
            data.append(contentsOf: buffer.prefix(count))
        }
        return data
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.requests.append(request); let mode = Self.streamMode; Self.lock.unlock()
        let path = request.url!.path
        var body = "{}"
        var contentType = "application/json"
        var status = 200
        switch path {
        case "/": body = "<html data-build=\"fixture\"><script src=\"/sdk.js\"></script></html>"; contentType = "text/html"
        case "/backend-api/sentinel/chat-requirements/prepare":
            body = mode == "challenge" ? #"{"turnstile":{"required":true},"prepare_token":"fixture-prepare"}"# : #"{"prepare_token":"fixture-prepare"}"#
            if ["dx", "bad-dx", "recoverable-dx", "no-result-dx", "budget-dx"].contains(mode) {
                let payload = try! JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
                let source = Array((payload["p"] as! String).unicodeScalars)
                // Opcode 2 stores a literal; opcode 7 calls result opcode 3 with its value.
                var instructions = #"[[2,100,"fixture-challenge"],[7,3,100]]"#
                if mode == "recoverable-dx" { instructions = #"[[7,3,999],[2,100,"fixture-challenge"],[7,3,100],[999]]"# }
                if mode == "no-result-dx" { instructions = #"[[7,3,999]]"# }
                if mode == "budget-dx" {
                    let nested = String(repeating: "[", count: 40) + "0" + String(repeating: "]", count: 40)
                    instructions = try! encoded([[2, 100, nested], [14, 101, 100], [3, "forbidden"]])
                }
                let encrypted = String(String.UnicodeScalarView(instructions.unicodeScalars.enumerated().map {
                    Unicode.Scalar($0.element.value ^ source[$0.offset % source.count].value)!
                }))
                let dx = mode == "bad-dx" ? "invalid!" : Data(encrypted.utf8).base64EncodedString()
                body = try! encoded(["turnstile": ["required": true, "dx": dx], "prepare_token": "fixture-prepare"])
            } else if mode == "arkose" {
                body = #"{"arkose":{"required":true},"prepare_token":"fixture-prepare"}"#
            }
        case "/backend-api/sentinel/chat-requirements/finalize":
            let payload = try! JSONSerialization.jsonObject(with: Self.body(request)) as! [String: Any]
            precondition(payload["prepare_token"] as? String == "fixture-prepare")
            precondition(payload["turnstile_token"] as? String == (["dx", "recoverable-dx"].contains(mode) ? Data("fixture-challenge".utf8).base64EncodedString() : ""))
            body = #"{"token":"fixture-requirement","so_token":"fixture-so"}"#
        case "/backend-api/conversation":
            contentType = "text/event-stream"
            let first = try! encoded(snapshot("reply", "Hello"))
            body = "data: \(first)\n\ndata: {\"p\":\"/message/content/parts/0\",\"o\":\"append\",\"v\":\" world\"}\n\n"
            if mode != "truncated" { body += "data: [DONE]\n\n" }
        default: fatalError("Unexpected endpoint: \(path)")
        }
        if mode == "403:" + path { status = 403; body = "credential-containing detail" }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": contentType])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        // Deliberately split UTF-8/SSE bytes across callbacks.
        let bytes = Data(body.utf8)
        for offset in stride(from: 0, to: bytes.count, by: 7) { client?.urlProtocol(self, didLoad: bytes.subdata(in: offset..<min(bytes.count, offset + 7))) }
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
    static func setMode(_ mode: String) { lock.lock(); streamMode = mode; requests = []; lock.unlock() }
    static func collectedRequests() -> [URLRequest] { lock.lock(); defer { lock.unlock() }; return requests }
}

@main struct Main {
    static func main() async throws {
        let vectors: [(String, String)] = __SHA_VECTORS__
        for (input, expected) in vectors {
            let digest = ChatGPTWebProtocol.sha3_512(Array(input.utf8)).map { String(format: "%02x", $0) }.joined()
            precondition(digest == expected, "SHA3-512 digest mismatch")
        }
        let config: [Any] = [1, "date", 2, 1, "ua", "script", "build", "en", "en", 0.5, "tail"]
        let serialized = try JSONSerialization.data(withJSONObject: config)
        let proof = try ChatGPTWebProtocol.solveProof(seed: "fixture", difficulty: "ff", serializedConfig: serialized, maxAttempts: 1)
        precondition(proof.hasPrefix("gAAAAAB"))
        let proofBytes = Data(base64Encoded: String(proof.dropFirst(7)))!
        let solved = try JSONSerialization.jsonObject(with: proofBytes) as! [Any]
        precondition(solved[3] as? Int == 0 && solved[9] as? Int == 0)
        expectError({ _ = try ChatGPTWebProtocol.solveProof(seed: "x", difficulty: "zz", serializedConfig: serialized) }, isMalformed)
        expectError({ _ = try ChatGPTWebProtocol.solveProof(seed: "x", difficulty: "ff", serializedConfig: serialized, maxAttempts: 0) }, {
            if case ChatGPTWebError.proofBudgetExceeded = $0 { return true }; return false
        })
        print("PASS: SHA3-512 known answers, proof format, malformed target, bounded work")

        var parser = ChatGPTWebStreamParser(historyIDs: ["old"])
        require(try parser.consume(encoded(snapshot("old", "Old assistant"))) == nil)
        require(try parser.consume(encoded(snapshot("user", "User echo", role: "user"))) == nil)
        require(try parser.consume(encoded(snapshot("analysis", "Hidden reasoning", channel: "analysis"))) == nil)
        require(try parser.consume(#"{"p":"/message/content/parts/0","o":"append","v":"still hidden"}"#) == nil)
        require(try parser.consume(encoded(snapshot("tool", "Tool command", recipient: "browser"))) == nil)
        require(try parser.consume(encoded(snapshot("reply", "Hi"))) == "Hi")
        require(try parser.consume(#"{"p":"/message/content/parts/0","o":"append","v":" there"}"#) == " there")
        require(try parser.consume(#"{"v":"!"}"#) == "!")
        require(try parser.consume(encoded(snapshot("reply", "Hi there!"))) == nil)
        require(try parser.consume(encoded(snapshot("next", ""))) == nil)
        require(try parser.consume(#"{"o":"patch","v":[{"p":"/message/content/parts/0","o":"append","v":"Second"}]}"#) == "\n\nSecond")
        require(try parser.consume(#"{"p":"/message/channel","o":"replace","v":"analysis"}"#) == nil)
        require(try parser.consume(#"{"p":"/message/content/parts/0","o":"append","v":"SECRET"}"#) == nil)
        require(try parser.consume("[DONE]") == nil && parser.finished)
        var interrupted = ChatGPTWebStreamParser()
        _ = try interrupted.consume(encoded(snapshot("x", "Text")))
        precondition(!interrupted.finished)
        expectError({ _ = try interrupted.consume(#"{"p":"/message/content/parts/0","o":"replace","v":"Rewritten"}"#) }, {
            if case ChatGPTWebError.rewrittenResponse = $0 { return true }; return false
        })
        var errored = ChatGPTWebStreamParser()
        expectError({ _ = try errored.consume(#"{"error":{"message":"credential-containing detail"}}"#) }, isMalformed)
        var citations = ChatGPTWebStreamParser()
        require(try citations.consume(encoded(snapshot("cite", "Hello\u{e200}cite"))) == "Hello")
        require(try citations.consume(encoded(snapshot("cite", "Hello\u{e200}cite\u{e202}turn0\u{e201} world"))) == " world")
        print("PASS: snapshots, patches, hidden channels, history IDs, rewrite errors, citation fragments")

        var sse = ChatGPTWebSSEDecoder()
        require(try sse.consume(line: ": heartbeat") == nil)
        require(try sse.consume(line: "data: {\"v\":") == nil)
        require(try sse.consume(line: "data: \"x\"}") == "{\"v\":\n\"x\"}")
        require(try sse.consume(line: "data: {}") == "{}")
        require(try sse.consume(line: "data:[DONE]") == "[DONE]")
        let message = ChatGPTWebProtocol.message(role: "user", text: "hello", id: "fixed")
        let body = ChatGPTWebProtocol.payload(messages: [message], model: "auto", timezone: TimeZone(secondsFromGMT: 8 * 3600)!)
        precondition(body["timezone_offset_min"] as? Int == -480)
        precondition(body["history_and_training_disabled"] as? Bool == true)
        precondition(body["tools"] == nil && body["max_tokens"] == nil)
        for status in [401, 403, 429, 500] {
            let response = HTTPURLResponse(url: URL(string: "https://chatgpt.com")!, statusCode: status, httpVersion: nil, headerFields: nil)!
            expectError({ try ChatGPTWebProtocol.checkHTTP(response, stage: .models) }, { error in
                switch error {
                case ChatGPTWebError.authenticationExpired: return status == 401
                case ChatGPTWebError.browserVerificationRequired(let stage): return status == 403 && stage == .models
                case ChatGPTWebError.rejected(let actual): return actual == status && [429, 500].contains(status)
                default: return false
                }
            })
        }
        print("PASS: SSE framing, timezone and request schema, HTTP errors")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FixtureProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let provider = ChatGPTWebProvider(model: ChatGPTWebProvider.builtInModels[0], instanceId: "fixture-instance",
                                          tokenProvider: { "fixture-access" }, session: session)
        precondition(!provider.supportsNativeTools)
        let result = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "Hello")], systemPrompt: nil, maxTokens: 123, temperature: nil)
        precondition(result.text == "Hello world" && result.usage == nil)
        let requests = FixtureProtocol.collectedRequests()
        precondition(requests.count == 4)
        let conversation = requests.last!
        precondition(conversation.url?.absoluteString == "https://chatgpt.com/backend-api/conversation")
        precondition(conversation.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-access")
        precondition(conversation.value(forHTTPHeaderField: "OpenAI-Sentinel-Chat-Requirements-Token") == "fixture-requirement")
        precondition(conversation.value(forHTTPHeaderField: "OpenAI-Sentinel-SO-Token") == "fixture-so")
        precondition(conversation.value(forHTTPHeaderField: "OAI-Client-Build-Number") == "6708908")
        precondition(requests[0].value(forHTTPHeaderField: "Authorization") == nil)
        FixtureProtocol.setMode("truncated")
        do {
            _ = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "x")], systemPrompt: nil, maxTokens: 1, temperature: nil)
            fatalError("Truncated stream accepted")
        } catch ChatGPTWebError.incompleteResponse {}
        FixtureProtocol.setMode("challenge")
        do {
            _ = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "x")], systemPrompt: nil, maxTokens: 1, temperature: nil)
            fatalError("Browser challenge ignored")
        } catch ChatGPTWebError.challengeProtocolChanged(let failure) {
            precondition(failure.stage == .missing)
        }
        precondition(FixtureProtocol.collectedRequests().count == 2)
        FixtureProtocol.setMode("dx")
        let challenged = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "x")], systemPrompt: nil, maxTokens: 1, temperature: nil)
        precondition(challenged.text == "Hello world")
        let challengedRequests = FixtureProtocol.collectedRequests()
        precondition(challengedRequests.count == 4)
        precondition(challengedRequests.last!.value(forHTTPHeaderField: "OpenAI-Sentinel-Turnstile-Token") == Data("fixture-challenge".utf8).base64EncodedString())
        FixtureProtocol.setMode("bad-dx")
        do {
            _ = try await provider.sendMessage(messages: [], systemPrompt: nil, maxTokens: 1, temperature: nil)
            fatalError("Malformed challenge accepted")
        } catch ChatGPTWebError.challengeProtocolChanged(let failure) {
            precondition(failure.stage == .encoding)
        }
        precondition(FixtureProtocol.collectedRequests().count == 2)
        FixtureProtocol.setMode("recoverable-dx")
        let recovered = try await provider.sendMessage(messages: [LLMMessage(role: .user, content: "x")], systemPrompt: nil, maxTokens: 1, temperature: nil)
        precondition(recovered.text == "Hello world")
        precondition(FixtureProtocol.collectedRequests().count == 4)
        precondition(FixtureProtocol.collectedRequests().last!.value(forHTTPHeaderField: "OpenAI-Sentinel-Turnstile-Token") == Data("fixture-challenge".utf8).base64EncodedString())
        for (mode, expected) in [("no-result-dx", ChatGPTWebChallenge.Failure.Stage.result), ("budget-dx", .budget)] {
            FixtureProtocol.setMode(mode)
            do {
                _ = try await provider.sendMessage(messages: [], systemPrompt: nil, maxTokens: 1, temperature: nil)
                fatalError("Failed challenge reached conversation")
            } catch ChatGPTWebError.challengeProtocolChanged(let failure) {
                precondition(failure.stage == expected)
                let description = ChatGPTWebError.challengeProtocolChanged(failure).errorDescription ?? ""
                precondition(description.contains(failure.code) && !description.contains("fixture-access"))
            }
            precondition(FixtureProtocol.collectedRequests().count == 2)
        }
        FixtureProtocol.setMode("arkose")
        do {
            _ = try await provider.sendMessage(messages: [], systemPrompt: nil, maxTokens: 1, temperature: nil)
            fatalError("Interactive challenge ignored")
        } catch ChatGPTWebError.interactiveVerificationRequired {}
        precondition(FixtureProtocol.collectedRequests().count == 2)
        let stages: [(String, ChatGPTWebRequestStage, Int)] = [
            ("/", .bootstrap, 1), ("/backend-api/sentinel/chat-requirements/prepare", .prepare, 2),
            ("/backend-api/sentinel/chat-requirements/finalize", .finalize, 3), ("/backend-api/conversation", .conversation, 4)
        ]
        for (path, expected, count) in stages {
            FixtureProtocol.setMode("403:" + path)
            do {
                _ = try await provider.sendMessage(messages: [], systemPrompt: nil, maxTokens: 1, temperature: nil)
                fatalError("403 accepted")
            } catch ChatGPTWebError.browserVerificationRequired(let actual) {
                precondition(actual == expected)
                precondition(!(ChatGPTWebError.browserVerificationRequired(actual).errorDescription ?? "").contains("credential-containing"))
            }
            precondition(FixtureProtocol.collectedRequests().count == count)
        }
        do {
            _ = try await provider.streamAgentMessageClamped(messages: [], systemPrompt: nil, tools: [AgentToolDefinition()], maxTokens: 1, thinkingLevel: .off)
            fatalError("Tools accepted")
        } catch ChatGPTWebError.unsupportedTools {}
        do {
            var message = LLMMessage(role: .user, content: "x"); message.images = [Data([1])]
            _ = try await provider.streamMessage(messages: [message], systemPrompt: nil, maxTokens: 1, temperature: nil)
            fatalError("Image silently discarded")
        } catch ChatGPTWebError.unsupportedAttachment {}
        print("PASS: actual transport fixtures, auth headers, SSE output, challenge/truncation failures, tools/attachments gating")
    }
}
'''

vectors = [(text, hashlib.sha3_512(text.encode()).hexdigest()) for text in ("", "abc", "a" * 72, "a" * 200)]
HARNESS = HARNESS.replace("__SHA_VECTORS__", "[" + ",".join(f"({json.dumps(text)}, {json.dumps(digest)})" for text, digest in vectors) + "]")

compiler = shutil.which("swiftc")
if not compiler and shutil.which("xcrun"):
    compiler = subprocess.check_output(["xcrun", "--find", "swiftc"], text=True).strip()
if not compiler:
    print("ERROR: Swift toolchain absent; production wire fixtures require macOS CI.")
    raise SystemExit(2)

with tempfile.TemporaryDirectory(prefix="ze-chatgpt-web-") as directory:
    directory = Path(directory)
    stubs = directory / "AppTypes.swift"
    harness = directory / "Fixtures.swift"
    stubs.write_text(STUBS, encoding="utf-8")
    harness.write_text(HARNESS, encoding="utf-8")
    binary = directory / "fixtures"
    subprocess.run([compiler, "-swift-version", "5", "-parse-as-library", *map(str, SOURCES), str(stubs), str(harness), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True, timeout=45)
