#!/usr/bin/env python3
"""Validate the bundled catalog and compile production thinking rules on macOS."""
import json
import platform
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
catalog = json.loads((ROOT / "Resources/models-dev-api.json").read_text(encoding="utf-8"))
expected = {
    "openai": {"gpt-6.1-sol": (1_050_000, 128_000), "gpt-6.1-terra": (1_050_000, 128_000)},
    "anthropic": {name: (1_000_000, 128_000) for name in
                  ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5"]},
    "google": {"gemini-4-argon": (1_048_576, 32_768)},
    "deepseek": {"deepseek-flash": (1_048_576, 393_216)},
}
for provider, models in expected.items():
    for name, (context, output) in models.items():
        model = catalog[provider]["models"][name]
        assert model["id"] == name
        assert (model["limit"]["context"], model["limit"]["output"]) == (context, output)
        assert model["reasoning"] and model["tool_call"]
        assert model["modalities"]["output"] == ["text"]
assert catalog["deepseek"]["models"]["deepseek-flash"]["modalities"]["input"] == ["text", "image"]
assert catalog["deepseek"]["models"]["deepseek-v4-pro"]["modalities"]["input"] == ["text"]
print("PASS: refreshed model IDs, limits, reasoning/tools, and modality distinctions")

# Compile the actual production rule implementation, excluding only the UI's
# provider-store lookup. No copied implementation or network calls in this test.
rules = (ROOT / "Providers/ThinkingRules.swift").read_text(encoding="utf-8")
start = rules.index("    @MainActor\n    static func builtInRulesForDisplay")
end = rules.index("    static func requestPreview", start)
rules = rules[:start] + rules[end:]
types = (ROOT / "Providers/LLMTypes.swift").read_text(encoding="utf-8")
start = types.index("enum ThinkingLevel:")
end = types.index("extension LLMModel", start)
levels = types[start:end]
anthropic = (ROOT / "Providers/Anthropic/AnthropicProvider.swift").read_text(encoding="utf-8")
start = anthropic.index("    static func parseClaudeVersion")
end = anthropic.index("    /// Applies the per-model temperature policy", start)
anthropic = "enum AnthropicProvider {\n" + anthropic[start:end] + "\n}\ntypealias AnthropicContract = AnthropicProvider\n"
openai = (ROOT / "Providers/OpenAI/OpenAIAgentProvider.swift").read_text(encoding="utf-8")
start = openai.index("    static func isGPT6Family")
end = openai.index("    /// Inject provider-specific thinking parameters", start)
namespace_start = types.index("    static func modelIdentifierWithoutNamespace")
namespace_end = types.index("    /// Compatibility", namespace_start)
namespace_helper = types[namespace_start:namespace_end]
openai = ("struct LLMModel { let id: String; let supportsReasoning: Bool?\n" + namespace_helper + "}\n"
          + "enum OpenAIContract {\n" + openai[start:end] + "\n}\n")
patcher = (ROOT / "Providers/Anthropic/OAuthHTTPClient.swift").read_text(encoding="utf-8")
config_start = patcher.index("    private static let thinkingLock")
config_end = patcher.index("    // MARK: - Compat-proxy reasoning echo", config_start)
wire_start = patcher.index("    static func injectThinkingConfig")
wire_end = patcher.index('    /// Injects `"ttl": "1h"`', wire_start)
patcher = ("enum RequestBodyPatcher {\n" + patcher[config_start:config_end]
           + patcher[wire_start:wire_end] + "\n}\n")
agent = (ROOT / "Providers/Anthropic/AnthropicAgentProvider.swift").read_text(encoding="utf-8")
start = agent.index("    static func thinkingEffort")
end = agent.index("    // MARK: - Message Conversion", start)
agent = "enum AgentContract {\n" + agent[start:end] + "\n}\n"
levels_catalog = (ROOT / "Providers/ThinkingLevelCatalog.swift").read_text(encoding="utf-8")
checks = r'''
let expected: [(ThinkingLevel, String)] = [(.low, "low"), (.medium, "high"),
    (.high, "high"), (.xhigh, "high"), (.max, "max"), (.ultra, "max")]
let instance = "model-compatibility-regression"
ThinkingRuleCache.shared.replace([
    ThinkingRule(label: "native", scope: .allModels, format: .deepSeekV4)
], for: instance)
for (level, effort) in expected {
    var body: [String: Any] = [:]
    precondition(ThinkingRuleResolver.applyCustomRule(to: &body,
        instanceId: instance, modelId: "deepseek-flash", level: level))
    precondition(body["reasoning_effort"] as? String == effort)
    precondition((body["thinking"] as? [String: String])?["type"] == "enabled")
    precondition((body["thinking"] as? [String: String])?["reasoning_effort"] == nil)
}
var disabled: [String: Any] = [:]
_ = ThinkingRuleResolver.applyCustomRule(to: &disabled, instanceId: instance,
    modelId: "deepseek-flash", level: .off)
precondition((disabled["thinking"] as? [String: String])?["type"] == "disabled")
precondition(disabled["reasoning_effort"] == nil)
for level in ThinkingLevel.allCases {
    precondition(ThinkingRuleResolver.geminiThinkingConfig(modelId: "gemini-4-argon", level: level).isEmpty)
    precondition(ThinkingRuleResolver.geminiThinkingConfig(modelId: "models/gemini-4-argon", level: level).isEmpty)
}
let legacy = ThinkingRuleResolver.geminiThinkingConfig(modelId: "gemini-3.8-flash", level: .off)
precondition(legacy["thinkingLevel"] as? String == "low")
let budget = ThinkingRuleResolver.geminiThinkingConfig(modelId: "gemini-2.5-flash", level: .off)
precondition(budget["thinkingBudget"] as? Int == 0)
for id in ["claude-opus-5-5", "claude-sonnet-5-5", "claude-haiku-5-5", "anthropic/claude-haiku-5.5"] {
    precondition(AnthropicContract.parseClaudeVersion(id)?.major == 5)
    precondition(AnthropicContract.parseClaudeVersion(id)?.minor == 5)
    precondition(AnthropicContract.modelUsesAdaptiveThinking(id))
    precondition(AnthropicContract.modelRejectsTemperature(id))
}
precondition(!AnthropicContract.modelUsesAdaptiveThinking("claude-haiku-4-5"))
for id in ["gpt-6.1-sol", "gpt-6.1-terra", "gpt-6.2", "openai/gpt-6.2", "vendor/gpt6.2"] {
    let model = LLMModel(id: id, supportsReasoning: true)
    precondition(OpenAIContract.reasoningEffort(for: model, level: .high) == "high")
    precondition(OpenAIContract.reasoningEffort(for: model, level: .ultra) == "max")
    precondition(OpenAIContract.reasoningEffort(for: model, level: .off) == nil)
}
print("PASS: production thinking rules compiled and executed")
'''
compiler = shutil.which("swiftc")
with tempfile.TemporaryDirectory(prefix="ze-model-compat-") as directory:
    source = Path(directory) / "main.swift"
    wire_checks = (ROOT / "scripts/AnthropicRequestWireChecks.swift").read_text(encoding="utf-8")
    source.write_text(rules + "\n" + levels + "\n" + anthropic + openai + patcher + agent + levels_catalog + checks + wire_checks, encoding="utf-8")
    if compiler:
        binary = Path(directory) / "model-tests"
        subprocess.run([compiler, "-target", f"{platform.machine()}-apple-macosx13.0", str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    else:
        print("SKIP: swiftc is absent; production Swift execution requires the macOS CI runner")
