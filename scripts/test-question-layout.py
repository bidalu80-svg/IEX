#!/usr/bin/env python3
"""Execute production question typography/cache contracts on the macOS runner."""
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
view = (root / "Views/Chat/AssistantBlockView.swift").read_text(encoding="utf-8")
typography = view[view.index("struct QuestionAskTypography:"):view.index("extension QuestionAskTypography")]
cache = view[view.index("enum QuestionPendingLayoutCache"):view.index("// END QuestionPendingLayoutCache")]
checks = r'''
let t = QuestionAskTypography(body: 16.5)
precondition(t.question == 16.5 && t.optionTitle == 16 && t.optionDetail == 13.5)
precondition(t.secondary == 14.5 && t.title == 15 && t.meta == 12.5)
precondition(t.chip == 11 && t.button == 16 && t.icon == 17)
precondition(t.resolvedTopic == 14.5 && t.resolvedDetail == 13)
let small = QuestionAskTypography(body: 8)
precondition(small.question == 13 && small.optionDetail == 12 && small.button == 14)
let large = QuestionAskTypography(body: 24)
precondition(large.question == 24 && large.optionTitle > t.optionTitle)
let a = QuestionPendingLayoutCache.key("question", 0)
let b = QuestionPendingLayoutCache.key("question", 1)
QuestionPendingLayoutCache.setBodyHeight(271.5, a)
QuestionPendingLayoutCache.setExpanded(true, a)
precondition(QuestionPendingLayoutCache.bodyHeight(a) == 271.5)
precondition(QuestionPendingLayoutCache.bodyHeight(b) == 0)
precondition(QuestionPendingLayoutCache.isExpanded(a))
precondition(!QuestionPendingLayoutCache.isExpanded(b))
QuestionPendingLayoutCache.setExpanded(false, a)
precondition(!QuestionPendingLayoutCache.isExpanded(a))
print("PASS: production question typography and per-question reuse cache")
'''
compiler = shutil.which("swiftc")
if not compiler:
    print("SKIP: swiftc absent; typography/cache execution requires the macOS runner")
else:
    with tempfile.TemporaryDirectory(prefix="question-layout-") as directory:
        source = Path(directory) / "main.swift"
        source.write_text("import Foundation\n" + typography + cache + checks, encoding="utf-8")
        binary = Path(directory) / "question-layout-tests"
        subprocess.run([compiler, str(source), "-o", str(binary)], check=True)
        subprocess.run([str(binary)], check=True)
