import Foundation
import CryptoKit

enum WorkBuddyRequestAdapter {
    static func streamValidator() -> (String?) throws -> Void {
        var receivedChoice = false
        var completed = false
        return { line in
            guard let line else {
                guard receivedChoice, completed else { throw WorkBuddyError.message("WorkBuddy 响应为空或传输未完成，请重试。") }
                return
            }
            guard line.hasPrefix("data:") else {
                // A JSON error envelope can arrive instead of SSE with HTTP 200.
                if line.trimmingCharacters(in: .whitespaces).hasPrefix("{") {
                    throw WorkBuddyError.message("WorkBuddy 返回了非流式响应，请检查账号状态。")
                }
                return
            }
            let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
            if payload == "[DONE]" { completed = true; return }
            guard let data = payload.data(using: .utf8), let event = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                throw WorkBuddyError.message("WorkBuddy 流式响应格式错误。")
            }
            if event["error"] != nil || (event["code"] as? Int).map({ $0 != 0 }) == true {
                throw WorkBuddyError.message("WorkBuddy 流式请求失败，请检查账号状态后重试。")
            }
            if let choices = event["choices"] as? [[String: Any]], !choices.isEmpty {
                receivedChoice = true
                if choices.contains(where: { $0["finish_reason"] as? String != nil }) { completed = true }
            }
        }
    }

    @MainActor
    static func adapt(_ input: URLRequest, instanceId: String, model: LLMModel, conversationID: String, turnID: String) async throws -> URLRequest {
        let initialCredentials = try await WorkBuddyOAuthManager.shared.validCredentials(instanceId: instanceId)
        let session = WorkBuddyOAuthManager.shared.credentialSession(instanceId: instanceId)
        let capabilities = try await WorkBuddyModelsAPI.requiredCapabilities(instanceId: instanceId, modelID: model.id, credentials: initialCredentials)
        // A cold catalog request can take long enough to cross token expiry.
        let credentials = try await WorkBuddyOAuthManager.shared.validCredentials(instanceId: instanceId)
        guard credentials.uid == initialCredentials.uid, credentials.realm == initialCredentials.realm,
              WorkBuddyOAuthManager.shared.credentialSession(instanceId: instanceId) == session else { throw CancellationError() }
        guard let data = input.httpBody,
              var body = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw WorkBuddyError.message("WorkBuddy 聊天请求格式错误。")
        }
        body["stream"] = true
        body["stream_options"] = ["include_usage": true]
        if body["max_tokens"] == nil { body["max_tokens"] = body["max_completion_tokens"] }
        body.removeValue(forKey: "max_completion_tokens")
        // OpenRouter's nested reasoning object is not this service's schema.
        if let reasoning = body.removeValue(forKey: "reasoning") as? [String: Any], body["reasoning_effort"] == nil {
            body["reasoning_effort"] = reasoning["effort"]
        }
        if capabilities.supportsReasoning == false {
            body.removeValue(forKey: "reasoning_effort")
            body.removeValue(forKey: "thinking")
        } else if let requested = body["reasoning_effort"] as? String,
                  !capabilities.efforts.isEmpty, !capabilities.efforts.contains(requested) {
            let supported = capabilities.efforts
            let ranks = ["off", "none", "minimal", "low", "medium", "high", "xhigh", "max"]
            if let target = ranks.firstIndex(of: requested) {
                let ranked = supported.compactMap { value -> (String, Int)? in
                    guard let index = ranks.firstIndex(of: value) else { return nil }
                    return (value, index)
                }.sorted { $0.1 < $1.1 }
                body["reasoning_effort"] = ranked.last(where: { $0.1 <= target })?.0 ?? ranked.first?.0
            }
        }
        if capabilities.supportsTools != true, let tools = body["tools"] as? [Any], !tools.isEmpty {
            throw WorkBuddyError.message("当前 WorkBuddy 模型未提供工具调用能力，请选择其他模型。")
        }
        if let choice = body["tool_choice"] as? [String: Any] {
            let type = choice["type"] as? String ?? "auto"
            body["tool_choice"] = type == "function" ? ((choice["function"] as? [String: Any])?["name"] as? String ?? "auto") : type
        }
        if body["tool_choice"] as? String == "none" {
            body.removeValue(forKey: "tool_choice")
            body.removeValue(forKey: "tools")
            body.removeValue(forKey: "functions")
        }
        var messages = body["messages"] as? [[String: Any]] ?? []
        for index in messages.indices {
            if messages[index]["role"] as? String == "developer" { messages[index]["role"] = "system" }
            if var parts = messages[index]["content"] as? [[String: Any]] {
                for partIndex in parts.indices where parts[partIndex]["type"] as? String == "image_url" {
                    if capabilities.supportsImages != true {
                        throw WorkBuddyError.message("当前 WorkBuddy 模型未提供图片理解能力。")
                    }
                    if let url = parts[partIndex]["image_url"] as? String { parts[partIndex]["image_url"] = ["url": url] }
                }
                messages[index]["content"] = parts
            }
        }
        if credentials.realm == .global, messages.first?["role"] as? String != "system" {
            messages.insert(["role": "system", "content": "You are a helpful assistant."], at: 0)
        }
        body["messages"] = messages
        var request = input
        request.url = URL(string: credentials.realm.baseURL + "/v2/chat/completions")
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        var headers = WorkBuddyHTTP.commonHeaders(realm: credentials.realm)
        headers["Accept"] = "application/json, text/event-stream"
        headers["Authorization"] = "Bearer \(credentials.accessToken)"
        headers["X-User-Id"] = credentials.uid
        if credentials.realm == .global {
            headers["X-No-Enterprise-Id"] = "1"
            headers["X-Domain"] = "www.workbuddy.ai"
        } else {
            if let enterprise = credentials.enterpriseID, !enterprise.isEmpty { headers["X-Enterprise-Id"] = enterprise }
            else { headers["X-No-Enterprise-Id"] = "1" }
            if let domain = credentials.domain, !domain.isEmpty { headers["X-Domain"] = domain }
            else { headers["X-No-Department-Info"] = "1" }
        }
        if let device = credentials.deviceToken, !device.isEmpty { headers["X-Device-Token"] = device }
        headers["X-Machine-ID"] = stableID("machine:\(instanceId):\(credentials.uid)")
        headers["X-Session-ID"] = stableID("session:\(instanceId):\(credentials.uid)")
        headers["X-Agent-Purpose"] = "conversation"
        headers["X-IDE-Name"] = "WorkBuddy"
        headers["X-IDE-Type"] = "WorkBuddy"
        headers["X-IDE-Version"] = "5.5.4"
        headers["X-Product"] = "WorkBuddy"
        headers["X-Conversation-ID"] = conversationID
        headers["X-Conversation-Request-ID"] = turnID
        headers["X-Root-Request-ID"] = turnID
        headers["X-Trace-ID"] = turnID
        let messageID = newID()
        headers["X-Conversation-Message-ID"] = messageID
        headers["X-Request-ID"] = messageID
        headers["X-B3-TraceId"] = turnID
        headers["X-B3-SpanId"] = String(messageID.prefix(16))
        headers["X-B3-Sampled"] = "1"
        request.setValue(nil, forHTTPHeaderField: "X-Refresh-Token")
        for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
        return request
    }

    static func newID() -> String { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }

    private static func stableID(_ input: String) -> String {
        SHA256.hash(data: Data(input.utf8)).prefix(18).map { String(format: "%02x", $0) }.joined()
    }
}
