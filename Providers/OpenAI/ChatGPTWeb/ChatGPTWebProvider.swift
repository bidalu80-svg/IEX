import Foundation

/// Direct, experimental ChatGPT web transport. Credentials and endpoints are isolated
/// from Codex. Web verification may reject native networking even after OAuth succeeds.
final class ChatGPTWebProvider: LLMProvider, AgentProvider {
    let name = "ChatGPT 网页（实验）"
    var model: LLMModel
    let providerInstanceId: String?
    var defaultMaxTokens: Int { model.maxOutputTokens ?? 4096 }
    var supportsNativeTools: Bool { false }
    private let tokenProvider: () async throws -> String
    private let session: URLSession
    private let deviceId: String
    private let sessionId = UUID().uuidString.lowercased()
    private let userAgent: String

    static let builtInModels = [LLMModel(id: "auto", displayName: "ChatGPT 自动（实验）",
                                         provider: "OpenAI", modalityOverride: .textOnly, supportsReasoning: false)]

    init(model: LLMModel, instanceId: String, tokenProvider: @escaping () async throws -> String,
         session: URLSession? = nil) {
        self.model = model
        self.providerInstanceId = instanceId
        self.deviceId = instanceId
        self.tokenProvider = tokenProvider
        let version = ProcessInfo.processInfo.operatingSystemVersion
        self.userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS \(version.majorVersion)_\(version.minorVersion) like Mac OS X) AppleWebKit/605.1.15 Version/16.0 Mobile/15E148 Safari/604.1"
        if let session { self.session = session }
        else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 120
            configuration.timeoutIntervalForResource = 1800
            self.session = URLSession(configuration: configuration)
        }
    }

    func sendMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> LLMResponse {
        let stream = try await streamMessage(messages: messages, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: temperature)
        var text = ""
        for try await event in stream { if case .text(let delta) = event { text += delta } }
        // Web responses do not report API token usage. Do not fabricate zero usage.
        return LLMResponse(text: text, stopReason: "end_turn", usage: nil)
    }

    func streamMessage(messages: [LLMMessage], systemPrompt: String?, maxTokens: Int, temperature: Double?) async throws -> AsyncThrowingStream<LLMStreamChunk, Error> {
        guard messages.allSatisfy({ $0.images.isEmpty && $0.audios.isEmpty }) else {
            throw ChatGPTWebError.unsupportedAttachment
        }
        var wire: [[String: Any]] = []
        if let systemPrompt, !systemPrompt.isEmpty { wire.append(ChatGPTWebProtocol.message(role: "system", text: systemPrompt)) }
        wire += messages.map { ChatGPTWebProtocol.message(role: $0.role.rawValue, text: $0.content) }
        let body = ChatGPTWebProtocol.payload(messages: wire, model: model.id)
        let historyIDs = Set(wire.compactMap { $0["id"] as? String })
        let encoded = try JSONSerialization.data(withJSONObject: body)
        return AsyncThrowingStream { continuation in
            let task = Task { [self] in
                do {
                    try Task.checkCancellation()
                    let token = try await tokenProvider()
                    guard !token.isEmpty else { throw ChatGPTWebError.authenticationExpired }
                    let requirements = try await self.requirements(token: token)
                    var request = self.request(path: "/backend-api/conversation", token: token)
                    request.httpMethod = "POST"
                    request.httpBody = encoded
                    request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
                    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    for (field, value) in requirements { request.setValue(value, forHTTPHeaderField: field) }
                    let (bytes, response) = try await session.bytes(for: request)
                    try ChatGPTWebProtocol.checkHTTP(response)
                    guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.lowercased().contains("text/event-stream") == true else {
                        throw ChatGPTWebError.malformedResponse
                    }
                    continuation.yield(.started)
                    var parser = ChatGPTWebStreamParser(historyIDs: historyIDs)
                    var decoder = ChatGPTWebSSEDecoder()
                    var emitted = false
                    for try await line in bytes.lines {
                        try Task.checkCancellation()
                        if let payload = try decoder.consume(line: line), let delta = try parser.consume(payload) {
                            emitted = true
                            continuation.yield(.text(delta))
                        }
                        if parser.finished { break }
                    }
                    if let payload = decoder.flush(), let delta = try parser.consume(payload) {
                        emitted = true
                        continuation.yield(.text(delta))
                    }
                    guard parser.finished, emitted else { throw ChatGPTWebError.incompleteResponse }
                    continuation.yield(.finished(stopReason: "end_turn"))
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func streamAgentMessageClamped(messages: [AgentMessage], systemPrompt: String?, tools: [AgentToolDefinition], maxTokens: Int,
                                   thinkingLevel: ThinkingLevel) async throws -> AsyncThrowingStream<AgentStreamEvent, Error> {
        guard tools.isEmpty else { throw ChatGPTWebError.unsupportedTools }
        let plain: [LLMMessage] = try messages.map { message in
            var text = ""
            for part in message.parts {
                switch part {
                case .text(let value): text += value
                case .imageData: throw ChatGPTWebError.unsupportedAttachment
                case .toolUse, .toolResult: throw ChatGPTWebError.unsupportedTools
                }
            }
            return LLMMessage(role: message.role == .user ? .user : .assistant, content: text)
        }
        let upstream = try await streamMessage(messages: plain, systemPrompt: systemPrompt, maxTokens: maxTokens, temperature: nil)
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for try await chunk in upstream {
                        try Task.checkCancellation()
                        switch chunk {
                        case .started: continuation.yield(.contentBlockStart(.text))
                        case .text(let text): continuation.yield(.textDelta(text))
                        case .usage(let usage): continuation.yield(.usage(usage))
                        case .finished: continuation.yield(.done(stopReason: .endTurn))
                        }
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    static func fetchModels(instanceId: String, tokenProvider: @escaping () async throws -> String) async throws -> [LLMModel] {
        let provider = ChatGPTWebProvider(model: builtInModels[0], instanceId: instanceId, tokenProvider: tokenProvider)
        let token = try await tokenProvider()
        let data = try await provider.json(path: "/backend-api/models?history_and_training_disabled=true", token: token)
        guard let entries = data["models"] as? [[String: Any]] else { throw ChatGPTWebError.malformedResponse }
        var seen = Set<String>()
        let models: [LLMModel] = entries.compactMap { item in
            guard let slug = item["slug"] as? String, !slug.isEmpty, seen.insert(slug).inserted else { return nil }
            return LLMModel(id: slug, displayName: item["title"] as? String ?? slug,
                            provider: "OpenAI", modalityOverride: .textOnly, supportsReasoning: false)
        }
        guard !models.isEmpty else { throw ChatGPTWebError.malformedResponse }
        return models
    }

    private func request(path: String, token: String? = nil) -> URLRequest {
        // Paths are constants owned by this module; a custom base URL is never used
        // with web OAuth credentials.
        var request = URLRequest(url: URL(string: "https://chatgpt.com" + path)!)
        request.timeoutInterval = TimeInterval(ResponseIdleTimeoutSetting.seconds(forInstanceId: providerInstanceId))
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("https://chatgpt.com", forHTTPHeaderField: "Origin")
        request.setValue("https://chatgpt.com/", forHTTPHeaderField: "Referer")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(deviceId, forHTTPHeaderField: "OAI-Device-Id")
        request.setValue(sessionId, forHTTPHeaderField: "OAI-Session-Id")
        request.setValue("en-US", forHTTPHeaderField: "OAI-Language")
        // Wire version from the pinned reference; isolated here because the web
        // service can change its client contract independently of public APIs.
        request.setValue("prod-a194cd50d4416d3c0b47c740f206b12ce60f5887", forHTTPHeaderField: "OAI-Client-Version")
        request.setValue("6708908", forHTTPHeaderField: "OAI-Client-Build-Number")
        let route = String(path.split(separator: "?", maxSplits: 1)[0])
        request.setValue(route, forHTTPHeaderField: "X-OpenAI-Target-Path")
        request.setValue(route, forHTTPHeaderField: "X-OpenAI-Target-Route")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    private func json(path: String, token: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var request = request(path: path, token: token)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        }
        let (data, response) = try await session.data(for: request)
        try ChatGPTWebProtocol.checkHTTP(response)
        return try ChatGPTWebProtocol.object(from: data)
    }

    private func requirements(token: String) async throws -> [String: String] {
        var home = request(path: "/")
        home.setValue("text/html", forHTTPHeaderField: "Accept")
        let (htmlData, response) = try await session.data(for: home)
        try ChatGPTWebProtocol.checkHTTP(response)
        let html = String(data: htmlData, encoding: .utf8) ?? ""
        let config = ChatGPTWebProtocol.requirementsConfig(userAgent: userAgent, html: html, deviceId: deviceId)
        let source = try ChatGPTWebProtocol.requirementsToken(config: config)
        let base = "/backend-api/sentinel/chat-requirements"
        let prepared = try await json(path: base + "/prepare", token: token, body: ["p": source])
        for name in ["arkose", "turnstile"] {
            if let challenge = prepared[name] as? [String: Any], challenge["required"] as? Bool == true {
                throw ChatGPTWebError.browserVerificationRequired
            }
        }
        var proof = ""
        if let challenge = prepared["proofofwork"] as? [String: Any], challenge["required"] as? Bool == true {
            guard let seed = challenge["seed"] as? String, let difficulty = challenge["difficulty"] as? String else {
                throw ChatGPTWebError.malformedResponse
            }
            proof = try await ChatGPTWebProtocol.proofToken(seed: seed, difficulty: difficulty, config: config)
        }
        guard let prepareToken = prepared["prepare_token"] as? String, !prepareToken.isEmpty else {
            throw ChatGPTWebError.malformedResponse
        }
        let finalized = try await json(path: base + "/finalize", token: token,
                                       body: ["prepare_token": prepareToken, "proof_token": proof, "turnstile_token": ""])
        guard let requirement = finalized["token"] as? String, !requirement.isEmpty else { throw ChatGPTWebError.malformedResponse }
        var headers = ["OpenAI-Sentinel-Chat-Requirements-Token": requirement]
        if !proof.isEmpty { headers["OpenAI-Sentinel-Proof-Token"] = proof }
        if let so = finalized["so_token"] as? String, !so.isEmpty { headers["OpenAI-Sentinel-SO-Token"] = so }
        return headers
    }
}
