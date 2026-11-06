#!/usr/bin/env python3
"""Compile production catalog decoding and effective cached-model capability logic."""
from pathlib import Path
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
types = (ROOT / "Providers/LLMTypes.swift").read_text(encoding="utf-8")
# Include the actual model declaration, initialization, family normalization and
# modality inference. Exclude static catalogs and unrelated streaming protocols.
head = types[:types.index("    // [T-anthropic-context-window]")]
inference = types[types.index("    // MARK: - Modality Inference from Model Name"):
                  types.index("    // MARK: - Capability Lookup")]
levels = types[types.index("enum ThinkingLevel:"):types.index("extension LLMModel", types.index("enum ThinkingLevel:"))]
model = head + inference + """
    static let knownCapabilities: [String: ModelCapabilities] = [:]
    static let defaultCapabilities = ModelCapabilities(supportedModalities: .textOnly, supportedAuth: [.apiKey])
    var catalogMaxThinkingLevel: ThinkingLevel { .max }
}
""" + levels
entry = (ROOT / "Providers/ModelEntry.swift").read_text(encoding="utf-8")
api = (ROOT / "Providers/OpenAI/OpenAIModelsAPI.swift").read_text(encoding="utf-8")
api = "enum OpenAIModelsAPI {\n" + api[api.index("    static func parseModels("):api.index("// MARK: - Cache")]
dependencies = r'''
enum ModelsDevAPI {
    static func enrichModel(_ model: LLMModel) -> LLMModel { model }
    static func enrichModels(_ models: [LLMModel]) -> [LLMModel] { models }
}
struct FixtureLogger { func info(_ value: String) {} }
let logger = FixtureLogger()
enum LLMError: Error { case decodingError(underlying: Error) }
func modelDisplayName(from id: String) -> String { id }
'''
checks = r'''
func fetched(_ id: String, fields: [String: Any] = [:]) throws -> LLMModel {
    var row = fields; row["id"] = id
    let data = try JSONSerialization.data(withJSONObject: ["data": [row]])
    return try OpenAIModelsAPI.parseModels(data, filterOpenAIOnly: false)[0]
}
let imageIDs = ["gpt-image-2.5", "gpt-image-2.6", "gpt-image-2.6-flare", "gpt-image-2.6-sunburst", "openai/gpt-image-2.6-flare"]
let imageShape = LLMModel.gptImageModalities
for id in imageIDs {
    precondition(LLMModel.isGPTImageFamily(id))
    let fresh = try fetched(id)
    precondition(fresh.id == id, "Wire model ID must not lose the gateway namespace")
    precondition(fresh.modalityOverride == imageShape, "Missing /models metadata must infer exact image shape")
    precondition(fresh.modalityOverride!.contains(.imageOutput) && !fresh.modalityOverride!.contains(.textOutput), "Pure image route must not become text+image")
    let custom = LLMModel(id: id, displayName: id, provider: "OpenAI").withInferredModality()
    precondition(custom.modalityOverride == imageShape, "Custom model inference must match fetched catalog")
    let legacy = LLMModel(id: id, displayName: id, provider: "OpenAI", modalityOverride: .textOnly)
    let cached = ModelEntry(providerInstanceId: "fixture", model: legacy)
    let bytes = try JSONEncoder().encode(cached)
    let restored = try JSONDecoder().decode(ModelEntry.self, from: bytes)
    precondition(restored.baseModel.modalityOverride == .textOnly, "Repair must not rewrite original stored metadata")
    precondition(restored.model.modalityOverride == imageShape, "Existing persisted fallback must heal without refetch")
    var user = restored
    user.overrides.modalityOverride = .textOnly
    precondition(user.model.modalityOverride == .textOnly, "User override must retain final authority")
    user.overrides.modalityOverride = [.textInput, .imageOutput]
    precondition(user.model.modalityOverride == [.textInput, .imageOutput])
    let explicitText = try fetched(id, fields: ["input_modalities": ["text"], "output_modalities": ["text"]])
    precondition(explicitText.modalityOverride == .textOnly, "Parser must preserve explicit server metadata")
    // Legacy rows have no provenance for their text-only bitset. Effective view
    // intentionally repairs that exact shape, including explicit server text-only.
    precondition(ModelEntry(providerInstanceId: "fixture", model: explicitText).model.modalityOverride == imageShape)
    let multimodal = try fetched(id, fields: ["input_modalities": ["text", "image"], "output_modalities": ["text", "image"]])
    let rich = ModelEntry(providerInstanceId: "fixture", model: multimodal).model
    precondition(rich.modalityOverride == multimodal.modalityOverride, "Rich server modality must remain authoritative")
}
for id in ["gpt-image-", "gpt-image-foo", "gpt-image-2oops", "gpt-image-2.", "gpt-image-2.6-", "fake-gpt-image-2", "gpt-image-2.6/chat", "gpt-4o", "deepseek-v4-pro", "mistral-small"] {
    precondition(!LLMModel.isGPTImageFamily(id), "Family boundary incorrectly matched \(id)")
    let model = try fetched(id)
    precondition(model.modalityOverride == .textOnly)
    precondition(ModelEntry(providerInstanceId: "fixture", model: model).model.modalityOverride == .textOnly)
}
let voice = LLMModel(id: "whisper-1", displayName: "Whisper", provider: "OpenAI").withInferredModality()
precondition(voice.modalityOverride == [.audioInput, .textOutput], "ASR inference regression")
for id in ["gpt-6.2", "gpt6.2-sol", "openai/gpt-6.2", "OPENAI/GPT6.2-SOL"] {
    precondition(LLMModel.isGPT56CompatibleFamily(id))
    let model = try fetched(id, fields: ["context_window": 123456, "max_output_tokens": 8192, "supports_reasoning": false])
    precondition(model.contextWindow == 123456 && model.maxOutputTokens == 8192)
    precondition(ModelEntry(providerInstanceId: "fixture", model: model).model.supportsReasoning == false)
}
print("PASS: production image catalog decoding, cached round-trip repair, overrides, pure-image shape, and GPT namespace compatibility")
'''
with tempfile.TemporaryDirectory(prefix="ze-image-capabilities-") as directory:
    source = Path(directory) / "main.swift"
    source.write_text(model + entry + api + dependencies + checks, encoding="utf-8")
    compiler = shutil.which("swiftc")
    if compiler:
        binary = Path(directory) / "image-capabilities"
        subprocess.run([compiler, str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
    else:
        print("SKIP: swiftc absent; fixtures assembled, production Swift execution requires macOS CI")
