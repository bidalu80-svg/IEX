#!/usr/bin/env python3
"""Compile actual GPT image wire helpers; no API credentials or network needed."""
from pathlib import Path
import re
import shutil
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
source = (ROOT / "Providers/OpenAI/OpenAIProvider.swift").read_text(encoding="utf-8")
types = (ROOT / "Providers/LLMTypes.swift").read_text(encoding="utf-8")
wire = source.split("// BEGIN GPTImageWireCompatibility", 1)[1].split("// END GPTImageWireCompatibility", 1)[0]

def function(text, name):
    start = text.index("    static func " + name)
    brace = text.index("{", start)
    # These two helpers contain a regex string with balanced braces (none).
    level = 1
    end = brace + 1
    while level:
        level += (text[end] == "{") - (text[end] == "}")
        end += 1
    return text[start:end]

family = "\n".join(function(types, name) for name in ("modelIdentifierWithoutNamespace", "isGPTImageFamily"))
swift = shutil.which("swiftc")
if swift is None:
    raise SystemExit("Image wire fixtures require swiftc (run on macOS CI).")

fixture = r'''
func check(_ value: @autoclosure () -> Bool, _ message: String) { precondition(value(), message) }
func expectFailure(_ operation: () throws -> Void) {
    do { try operation(); preconditionFailure("expected parameter failure") } catch {}
}
for model in ["gpt-image-2.5", "gpt-image-2.6", "gpt-image-2.6-flare", "gpt-image-2.6-sunburst", "openai/gpt-image-2.5-sunburst-2026-09-08", "openai/chatgpt-image-latest"] {
    let fields = try OpenAIProvider.imageRequestFields(modelID:model, prompt:"original", n:1, size:"1024x1024", quality:"high", extraBody:["response_format":"url", "model":"wrong", "quality":"max", "size":"1536x864", "output_format":"webp", "output_compression":90, "background":"transparent", "complexity":"high"])
    check(fields["model"] as? String == model, "wire model ID preserved")
    check(fields["response_format"] == nil, "GPT Image must not send legacy response_format")
    check(fields["quality"] as? String == "max", "new quality passthrough")
    check(fields["size"] as? String == "1536x864", "arbitrary size passthrough")
    let multipart = Dictionary(uniqueKeysWithValues: try OpenAIProvider.imageMultipartFields(fields))
    check(multipart["quality"] == "max" && multipart["output_compression"] == "90", "edit passthrough")
    check(multipart["response_format"] == nil, "edit legacy field absent")
}
let legacy = try OpenAIProvider.imageRequestFields(modelID:"grok-imagine-image", prompt:"p", n:1, size:nil, quality:nil, extraBody:["response_format":"url"])
check(legacy["response_format"] as? String == "url", "non-GPT provider explicit format unchanged")
for format in ["svg", "gif"] {
    expectFailure { _ = try OpenAIProvider.imageRequestFields(modelID:"gpt-image-2.6", prompt:"p", n:1, size:nil, quality:nil, extraBody:["output_format":format]) }
}
expectFailure { _ = try OpenAIProvider.imageRequestFields(modelID:"gpt-image-2.6", prompt:"p", n:1, size:nil, quality:nil, extraBody:["stream":true]) }
expectFailure { _ = try OpenAIProvider.imageMultipartFields(["mask":"fake-file"]) }
expectFailure { _ = try OpenAIProvider.imageMultipartFields(["bad\r\nfield":"x"]) }
expectFailure { try OpenAIProvider.validateImageResultMime("image/svg+xml; charset=utf-8") }
let booleans = Dictionary(uniqueKeysWithValues: try OpenAIProvider.imageMultipartFields(["watermark":false, "output_compression":100]))
check(booleans["watermark"] == "false" && booleans["output_compression"] == "100", "multipart boolean versus number")
print("GPT image wire fixtures passed: namespaces, aliases, generation/edit formats, passthrough, rendering constraints.")
'''

# Ensure fixture-tested helpers are used by both actual transport entry points.
assert source.count("Self.imageRequestFields(modelID: model.id") == 2
assert 'appendField("response_format", "b64_json")' not in source
assert 'let fieldName = images.count == 1 ? "image" : "image[]"' in source
with tempfile.TemporaryDirectory(prefix="ze-image-wire-") as directory:
    directory = Path(directory)
    main = directory / "main.swift"
    main.write_text("import Foundation\nimport CoreFoundation\nenum LLMError: Error { case providerError(message: String) }\nenum LLMModel {\n" + family + "\n}\nenum OpenAIProvider {\n" + wire + "\n}\n" + fixture, encoding="utf-8")
    binary = directory / "image-wire-fixtures"
    subprocess.run([swift, "-swift-version", "5", str(main), "-o", str(binary)], check=True)
    subprocess.run([str(binary)], check=True)
