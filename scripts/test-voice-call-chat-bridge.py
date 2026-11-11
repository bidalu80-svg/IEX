#!/usr/bin/env python3
"""Compile the production call text projection and check incremental code safety."""
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / "Agent/Chat/AIChatViewModel+VoiceCall.swift").read_text(encoding="utf-8")
production = source[:source.index("extension AIChatViewModel {")]
checks = r'''
var checks = 0
func verify(_ source: String, _ expected: String) {
    precondition(VoiceCallSpeechProjection.visibleText(source) == expected,
                 "unexpected projection for \(source)")
    checks += 1
}
verify("你好。今天怎么样？", "你好。今天怎么样？")
verify("说明。\n```swift\nprint(\"SECRET\")\n```\n结束。", "说明。\n结束。")
verify("说明。\n```swift\nprint(\"SECRET", "说明。")
verify("前文\n~~~~python\nSECRET\n~~~\nMORE_SECRET\n~~~~\n后文", "前文\n后文")
verify("前文\n    SECRET\n\tMORE_SECRET\n后文", "前文\n后文")
verify("运行 `SECRET` 后完成。", "运行  后完成。")
verify("运行 ``SECRET ` STILL_SECRET`` 后完成。", "运行  后完成。")
verify("说明 `SECRET", "说明 ")
let streaming = "你好。\n```swift\nlet SECRET = 123\n```\n已经完成。"
var prefix = ""
for character in streaming {
    prefix.append(character)
    precondition(!VoiceCallSpeechProjection.visibleText(prefix).contains("SECRET"))
    precondition(!VoiceCallSpeechProjection.visibleText(prefix).contains("let "))
    checks += 1
}
verify(streaming, "你好。\n已经完成。")
print("PASS: \(checks) production voice-call text projection checks")
'''

compiler = shutil.which("swiftc")
if compiler is None:
    print("SKIP: production Swift voice-call projection execution requires macOS swiftc")
else:
    with tempfile.TemporaryDirectory(prefix="ze-voice-call-text-") as temporary:
        file = Path(temporary) / "main.swift"
        binary = Path(temporary) / "voice-call-text-tests"
        file.write_text(production + checks, encoding="utf-8")
        subprocess.run([compiler, "-target", f"{platform.machine()}-apple-macosx13.0",
                        str(file), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
