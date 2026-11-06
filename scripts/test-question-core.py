#!/usr/bin/env python3
"""Compile and run the actual question core without the iOS app dependencies."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parent.parent
source = (root / "Agent/Chat/ChatLifecycleSupport.swift").read_text(encoding="utf-8")
start = source.index("struct QuestionCardQuestion:")
end = source.index("/// Owns the single pending question-card continuation", start)
with tempfile.TemporaryDirectory(prefix="ze-question-core-") as directory:
    generated = Path(directory) / "QuestionCardCore.swift"
    generated.write_text("import Foundation\n" + source[start:end], encoding="utf-8")
    executable = Path(directory) / "question-core-tests"
    subprocess.run(["swiftc", "-parse-as-library", str(generated), str(root / "scripts/QuestionCardCoreHarness.swift"), "-o", str(executable)], check=True)
    subprocess.run([str(executable)], check=True)
