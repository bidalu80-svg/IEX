#!/usr/bin/env python3
"""Compile the production parent callback helpers with a minimal chat fixture."""
from pathlib import Path
import subprocess
import tempfile
import sys

root = Path(__file__).resolve().parents[1]
source = (root / "Agent/Chat/AIChatViewModel+Misc.swift").read_text(encoding="utf-8")
start = source.index("    /// Programmatic child results")
end = source.index("    /// Withdraw a queued message", start)
generated = "import Foundation\nextension AIChatViewModel {\n" + source[start:end] + "\n}\n"
if len(sys.argv) == 3 and sys.argv[1] == "--extract":
    Path(sys.argv[2]).write_text(generated, encoding="utf-8")
    print(sys.argv[2])
else:
    with tempfile.TemporaryDirectory(prefix="ze-subagent-delivery-") as directory:
        swift = Path(directory) / "SubAgentDelivery.swift"
        swift.write_text(generated, encoding="utf-8")
        executable = Path(directory) / "subagent-delivery-tests"
        subprocess.run(["swiftc", "-parse-as-library", str(swift),
                        str(root / "scripts/SubAgentDeliveryHarness.swift"), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
