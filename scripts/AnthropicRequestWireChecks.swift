// Appended to the production rule/patcher extraction by test-model-compatibility.py.
func wire(_ id: String, _ intent: String?, _ extra: [String: Any] = [:]) -> ([String: Any], String?) {
    var json = extra
    json["model"] = id
    if json["messages"] == nil { json["messages"] = [["role": "user", "content": "hello"]] }
    let request = NSMutableURLRequest(url: URL(string: "https://api.anthropic.com/v1/messages")!)
    request.httpBody = try! JSONSerialization.data(withJSONObject: json)
    request.setValue("oauth-2025-04-20,effort-2025-11-24,interleaved-thinking-2025-05-14", forHTTPHeaderField: "anthropic-beta")
    switch intent {
    case "off": RequestBodyPatcher.setThinkingDisabled()
    case "budget": RequestBodyPatcher.setThinkingBudget(2048)
    case .some(let effort): RequestBodyPatcher.setThinkingEffort(effort)
    case nil: break
    }
    RequestBodyPatcher.injectThinkingConfig(into: request)
    return (try! JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any],
            request.value(forHTTPHeaderField: "anthropic-beta"))
}
let opusOff = wire("claude-opus-5-5", "off")
precondition(!ThinkingLevelCatalog.supportsThinkingOff(for: "anthropic/claude-opus-5.5"))
precondition(ThinkingLevelCatalog.supportsThinkingOff(for: "claude-sonnet-5-5"))
precondition(ThinkingLevelCatalog.supportsThinkingOff(for: "claude-opus-5"))
precondition(ThinkingLevelCatalog.normalizedLevel(.off, for: "claude-opus-5-5", maximum: .max) == .low)
precondition(ThinkingLevelCatalog.normalizedLevel(.off, for: "claude-opus-5-5", maximum: .off) == .low)
precondition(ThinkingLevelCatalog.normalizedLevel(.ultra, for: "claude-opus-5-5", maximum: .max) == .max)
precondition(ThinkingLevelCatalog.normalizedLevel(.off, for: "claude-sonnet-5-5", maximum: .max) == .off)
precondition((opusOff.0["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
precondition((opusOff.0["output_config"] as? [String: Any])?["effort"] as? String == "low")
let sonnetOff = wire("claude-sonnet-5-5", "off", ["output_config": ["effort": "max", "format": ["type": "json_schema"]],
    "thinking": ["type": "enabled", "budget_tokens": 500, "display": "summarized"]]).0
precondition((sonnetOff["thinking"] as? [String: String]) == ["type": "between_tools"])
precondition((sonnetOff["output_config"] as? [String: Any])?["effort"] as? String == "high")
precondition((sonnetOff["output_config"] as? [String: Any])?["format"] != nil)
let haikuOff = wire("claude-haiku-5-5", "off", ["output_config": ["effort": "xhigh"]]).0
precondition((haikuOff["thinking"] as? [String: String]) == ["type": "disabled"])
precondition((haikuOff["output_config"] as? [String: Any])?["effort"] as? String == "high")
for id in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "anthropic/claude-haiku-5.5", "claude-fable-5-2", "anthropic/claude-fable-5.2"] {
    precondition(ThinkingLevelCatalog.declaredMaxLevel(for: id) == .max)
    for level in ThinkingLevel.allCases where level.isEnabled {
        let effort = AgentContract.thinkingEffort(for: level, modelId: id)
        let response = wire(id, effort, ["temperature": 0.7, "top_p": 0.9, "top_k": 2])
        let body = response.0
        precondition((body["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        precondition((body["thinking"] as? [String: Any])?["display"] as? String == "summarized")
        precondition((body["thinking"] as? [String: Any])?["budget_tokens"] == nil)
        precondition((body["output_config"] as? [String: Any])?["effort"] as? String == effort)
        precondition(body["temperature"] == nil && body["top_p"] == nil && body["top_k"] == nil)
        precondition(response.1 == "oauth-2025-04-20")
    }
    let migrated = wire(id, "budget").0
    precondition((migrated["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    precondition((migrated["thinking"] as? [String: Any])?["budget_tokens"] == nil)
    let defaults = wire(id, nil, ["temperature": 0.4, "top_p": 0.8, "top_k": 5,
        "messages": [["role": "user", "content": "question"], ["role": "assistant", "content": "partial"]]]).0
    precondition(defaults["thinking"] == nil)
    precondition(defaults["temperature"] == nil && defaults["top_p"] == nil && defaults["top_k"] == nil)
    let history = defaults["messages"] as! [[String: Any]]
    precondition(history.count == 3 && history[1]["content"] as? String == "partial")
    precondition(history.last?["role"] as? String == "user")
}
for id in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-fable-5-2"] {
    let body = wire(id, nil, ["tool_choice": ["type": "tool", "name": "file_read", "disable_parallel_tool_use": true]]).0
    let choice = body["tool_choice"] as! [String: Any]
    precondition(choice["type"] as? String == "auto" && choice["name"] == nil)
    precondition(choice["disable_parallel_tool_use"] as? Bool == true)
}
let legacyOff = wire("claude-sonnet-4-6", "off").0
precondition((legacyOff["thinking"] as? [String: String]) == ["type": "disabled"])
let legacyBudget = wire("claude-haiku-4-5", "budget").0
precondition((legacyBudget["thinking"] as? [String: Any])?["budget_tokens"] as? Int == 2048)
let staleSonnet = wire("claude-sonnet-5-5", nil, ["thinking": ["type": "between_tools", "display": "summarized", "budget_tokens": 500],
    "output_config": ["effort": "xhigh"]]).0
precondition((staleSonnet["thinking"] as? [String: String]) == ["type": "between_tools"])
precondition((staleSonnet["output_config"] as? [String: Any])?["effort"] as? String == "high")
for id in ["claude-opus-5-5", "claude-haiku-5-5"] {
    let retried = wire(id, nil, ["thinking": ["type": "between_tools"], "output_config": ["effort": "max"]]).0
    precondition((retried["thinking"] as? [String: Any])?["type"] as? String != "between_tools")
}
let unknown = wire("claude-sonnet-6", nil, ["temperature": 0.7]).0
precondition(unknown["temperature"] as? Double == 0.7)
let chatRequest = NSMutableURLRequest(url: URL(string: "https://proxy.example/v1/chat/completions")!)
let chatBody = try! JSONSerialization.data(withJSONObject: ["model": "claude-sonnet-5-5", "temperature": 0.7])
chatRequest.httpBody = chatBody
RequestBodyPatcher.applyModelRequestRules(into: chatRequest)
precondition(chatRequest.httpBody == chatBody)
precondition(AgentContract.thinkingEffort(for: .xhigh, modelId: "claude-haiku-5-5") == "xhigh")
precondition(AgentContract.thinkingEffort(for: .xhigh, modelId: "claude-sonnet-4-6") == "max")
for id in ["claude-fable-5-2", "anthropic/claude-fable-5.2"] {
    precondition(AnthropicContract.parseClaudeVersion(id)?.minor == 2)
    precondition(!ThinkingLevelCatalog.supportsThinkingOff(for: id))
    precondition(ThinkingLevelCatalog.normalizedLevel(.off, for: id, maximum: .max) == .low)
    precondition(AgentContract.thinkingEffort(for: .xhigh, modelId: id) == "xhigh")
    for priorType in ["disabled", "between_tools"] {
        let off = wire(id, nil, ["thinking": ["type": priorType, "budget_tokens": 2048],
            "output_config": ["effort": "max", "format": ["type": "json_schema"]]]).0
        precondition((off["thinking"] as? [String: String]) == ["type": "adaptive", "display": "summarized"])
        precondition((off["output_config"] as? [String: Any])?["effort"] as? String == "low")
        precondition((off["output_config"] as? [String: Any])?["format"] != nil)
    }
    let off = wire(id, "off").0
    precondition((off["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    precondition((off["output_config"] as? [String: Any])?["effort"] as? String == "low")
    for intent in [nil, "budget"] as [String?] {
        let old = wire(id, intent, ["thinking": ["type": "enabled", "budget_tokens": 2048]]).0
        precondition((old["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
        precondition((old["thinking"] as? [String: Any])?["budget_tokens"] == nil)
        precondition((old["output_config"] as? [String: Any])?["effort"] as? String == "high")
    }
    for existingEffort in ["low", "medium", "high", "xhigh", "max"] {
        for existingType in ["adaptive", "enabled"] {
            let preserved = wire(id, nil, ["thinking": ["type": existingType, "budget_tokens": 2048],
                "output_config": ["effort": existingEffort]]).0
            precondition((preserved["output_config"] as? [String: Any])?["effort"] as? String == existingEffort)
        }
    }
    let any = wire(id, nil, ["tool_choice": ["type": "any"]]).0
    precondition((any["tool_choice"] as? [String: String])?["type"] == "auto")
    // Last-mile normalization must leave signed history byte-equivalent as JSON
    // content: Fable 5.2 validates thinking against the preceding conversation.
    let history: [[String: Any]] = [["role": "user", "content": "hello"],
        ["role": "assistant", "content": [["type": "thinking", "thinking": "", "signature": "opaque-signature"],
            ["type": "text", "text": "answer"]]], ["role": "user", "content": "follow up"]]
    let replay = wire(id, nil, ["messages": history]).0
    precondition(NSArray(array: replay["messages"] as! [[String: Any]]).isEqual(to: history))
}
precondition(ThinkingRuleResolver.claudeRequestFamily("claude-fable-5-20") == nil)
precondition(ThinkingRuleResolver.claudeRequestFamily("claude-fable-6") == nil)
print("PASS: production Anthropic request patcher serialized 5.5 and Fable 5.2 models, effort levels, and preserved history")
