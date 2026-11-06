#!/usr/bin/env python3
"""Execute production Chat/Responses reasoning builders for gateway model aliases.

Compatibility fixtures use supplied model IDs; they do not assert that an ID is an
officially released model or invent model limits. No live API requests are made.
"""
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
types = (ROOT / "Providers/LLMTypes.swift").read_text(encoding="utf-8")
levels = types[types.index("enum ThinkingLevel:"):types.index("extension LLMModel", types.index("enum ThinkingLevel:"))]
start = types.index("    static func modelIdentifierWithoutNamespace")
namespace = types[start:types.index("    /// Compatibility", start)]
model = "struct LLMModel { let id: String; let supportsReasoning: Bool?\n" + namespace + "}\n"
agent = (ROOT / "Providers/OpenAI/OpenAIAgentProvider.swift").read_text(encoding="utf-8")
start = agent.index("    static func isGPT6Family")
wire = "enum OpenAIContract {\n" + agent[start:agent.index("    // MARK: - DashScope Cache Control", start)] + "}\n"
# Exercise the same production helper that streamResponsesAPI calls, not a copied
# if/else in the fixture. Pin the call-site relation so dead helper tests fail.
responses = agent[agent.index("    private func streamResponsesAPI("):agent.index("    static func isGPT6Family")]
assert "Self.injectResponsesThinkingParams(" in responses
assert "into: &body, model: model, level: thinkingLevel, isCodexOAuth: isCodexOAuth" in responses
assert "Self.explicitOffEffort(for: provider, model: model, level: thinkingLevel)" in responses
assert "Self.injectThinkingParams(" in agent[:agent.index("    private func streamResponsesAPI(")]
rules = (ROOT / "Providers/ThinkingRules.swift").read_text(encoding="utf-8")
pattern_declaration = re.search(r'let openAIModels = (\[[^\n]+\])', rules).group(1)
start = rules.index("    @MainActor\n    static func builtInRulesForDisplay")
rules = rules[:start] + rules[rules.index("    static func requestPreview", start):]
catalog = (ROOT / "Providers/ThinkingLevelCatalog.swift").read_text(encoding="utf-8")

checks = r'''
func check(_ value: Bool) { precondition(value) }
func jsonWire(_ body: [String: Any]) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: JSONSerialization.data(withJSONObject: body)) as! [String: Any]
}
let ids = ["gpt-6.2", "openai/gpt-6.2", "gateway/openai/gpt-6.2", "vendor/gpt6.2", "OPENAI/GPT-6.2"]
let expected: [(ThinkingLevel, String)] = [(.low,"low"),(.medium,"medium"),(.high,"high"),(.xhigh,"xhigh"),(.max,"max"),(.ultra,"max")]
for id in ids {
    check(OpenAIContract.isGPT6Family(id))
    check(ThinkingLevelCatalog.declaredMaxLevel(for: id) == .max)
    for capability in [nil, true] as [Bool?] {
        let model = LLMModel(id: id, supportsReasoning: capability)
        for (level, effort) in expected {
            var chat: [String: Any] = ["model": id, "messages": [["role":"user","content":"fixture"]]]
            OpenAIContract.injectThinkingParams(into: &chat, model: model, level: level)
            let chatWire = try jsonWire(chat)
            check(chatWire["model"] as? String == id)
            check(chatWire["reasoning_effort"] as? String == effort)
            check(chatWire["reasoning"] == nil)
            var response: [String: Any] = ["model": id, "input": "fixture"]
            OpenAIContract.injectResponsesThinkingParams(into: &response, model: model, level: level, isCodexOAuth: false, offEffort: nil)
            let responseWire = try jsonWire(response)
            check(responseWire["model"] as? String == id)
            check((responseWire["reasoning"] as? [String: String])?["effort"] == effort)
            check((responseWire["reasoning"] as? [String: String])?["summary"] == "auto")
            check(responseWire["include"] as? [String] == ["reasoning.encrypted_content"])
            check(responseWire["reasoning_effort"] == nil)
        }
    }
    let negative = LLMModel(id: id, supportsReasoning: false)
    for level in ThinkingLevel.allCases {
        var chat: [String: Any] = [:]
        OpenAIContract.injectThinkingParams(into: &chat, model: negative, level: level, offEffort: "none")
        check(chat.isEmpty)
        var router: [String: Any] = [:]
        OpenAIContract.injectThinkingParams(into: &router, model: negative, level: level, isOpenRouter: true)
        check(router.isEmpty)
        for codex in [false, true] {
            var response: [String: Any] = [:]
            OpenAIContract.injectResponsesThinkingParams(into: &response, model: negative, level: level, isCodexOAuth: codex, offEffort: "none")
            check(response.isEmpty)
        }
    }
    let positive = LLMModel(id: id, supportsReasoning: true)
    var off: [String: Any] = [:]
    OpenAIContract.injectThinkingParams(into: &off, model: positive, level: .off, offEffort: "none")
    check(off["reasoning_effort"] as? String == "none")
    var responseOff: [String: Any] = [:]
    OpenAIContract.injectResponsesThinkingParams(into: &responseOff, model: positive, level: .off, isCodexOAuth: false, offEffort: "none")
    check((responseOff["reasoning"] as? [String:String]) == ["effort":"none"])
    check(responseOff["include"] == nil)
    var unknownOff: [String: Any] = [:]
    OpenAIContract.injectResponsesThinkingParams(into: &unknownOff, model: LLMModel(id:id, supportsReasoning:nil), level:.off, isCodexOAuth:false, offEffort:"none")
    check(unknownOff.isEmpty)
    var codex: [String: Any] = [:]
    OpenAIContract.injectResponsesThinkingParams(into: &codex, model: positive, level: .off, isCodexOAuth: true, offEffort: nil)
    check((codex["reasoning"] as? [String:String])?["effort"] == "low")
}
// The UI catalog expands supported patterns; user-authored glob semantics remain
// anchored to the full model ID. An exact/bare pattern must not gain a namespace.
let uiPatterns: [String] = __UI_PATTERNS__
for id in ids {
    check(uiPatterns.contains { ThinkingRule.Scope.modelPattern($0).matches(id) })
}
check(!ThinkingRule.Scope.modelPattern("gpt-6*").matches("openai/gpt-6.2"))
check(ThinkingRule.Scope.modelPattern("*/gpt-6*").matches("openai/gpt-6.2"))
let instance = "wire-rules"
ThinkingRuleCache.shared.replace([ThinkingRule(label:"bare only",scope:.modelPattern("gpt-6*"),format:.omit)],for:instance)
var scoped: [String: Any] = [:]
OpenAIContract.injectThinkingParams(into:&scoped,model:LLMModel(id:"openai/gpt-6.2",supportsReasoning:nil),level:.high,providerInstanceId:instance)
check(scoped["reasoning_effort"] as? String == "high")
ThinkingRuleCache.shared.replace([ThinkingRule(label:"explicit override",scope:.allModels,format:.nestedReasoningEffort)],for:instance)
var custom: [String:Any] = [:]
OpenAIContract.injectThinkingParams(into:&custom,model:LLMModel(id:"openai/gpt-6.2",supportsReasoning:nil),level:.ultra,providerInstanceId:instance)
check((custom["reasoning"] as? [String:String])?["effort"] == "max")
check(custom["reasoning_effort"] == nil)
check(!OpenAIContract.isGPT6Family("gpt-image-2"))
check(!OpenAIContract.isGPT6Family("vendor/gpt-5.5"))
print("PASS: production Chat/Responses serialized reasoning fields, namespace aliases, explicit false/off, ultra=max, UI patterns and custom scope semantics")
'''.replace("__UI_PATTERNS__", pattern_declaration)

compiler = shutil.which("swiftc")
if not compiler:
    raise SystemExit("Swift compiler required: run reasoning wire fixtures on macOS CI")
with tempfile.TemporaryDirectory(prefix="ze-reasoning-wire-") as temp:
    source = Path(temp) / "main.swift"
    source.write_text("import Foundation\n" + model + levels + rules + catalog + wire + checks, encoding="utf-8")
    binary = Path(temp) / "tests"
    subprocess.run([compiler, "-target", f"{platform.machine()}-apple-macosx13.0", str(source), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
