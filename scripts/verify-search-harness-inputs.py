#!/usr/bin/env python3
from pathlib import Path
from contextlib import nullcontext
import subprocess
import sys
from tempfile import TemporaryDirectory


root = Path(__file__).resolve().parents[1]
parser = (root / "Agent/Markdown/ZeMarkdownParser.swift").read_text(encoding="utf-8")
segment_id = parser.split("struct SimpleSegmentID:", 1)[1].split("// MARK: - MarkdownContent", 1)[0]
with nullcontext(Path(sys.argv[1]).resolve()) if len(sys.argv) > 1 else TemporaryDirectory() as directory:
    output = Path(directory)
    fixtures = (
        ("extract-question-ui.py", [output / "Question.swift"], "Question.swift"),
        ("extract-subagent-ui.py", [output / "SubAgent.swift"], "SubAgent.swift"),
        ("extract-subagent-full-detail.py", ["--production-only", output / "Reference.swift", output / "Reference.app", output / "evidence"],
         "ZeSubAgentFullDetailProduction.swift"),
    )
    for script, arguments, filename in fixtures:
        subprocess.run([sys.executable, str(root / "scripts" / script), *arguments], check=True, stdout=subprocess.DEVNULL)
        source = (output / filename).read_text(encoding="utf-8")
        assert source.count("struct SimpleSegmentID:" + segment_id) == 1, f"{script}: Missing or duplicated production SimpleSegmentID"
        assert source.count("struct ChatSearchUnitKey:") == 1 and "var segmentID: SimpleSegmentID?" in source, f"{script}: Missing production search key"
        print(f"PASS: {script} includes one production segment ID and search key")
