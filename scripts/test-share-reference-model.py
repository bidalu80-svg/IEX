#!/usr/bin/env python3
"""Run unchanged upstream behavioral cases against reference and shipping model.

The upstream planner supplies reference fold inputs only. Production fold wiring
is a separate application test; upstream source-string wiring assertions are not
run against the different Ze file layout.
"""
import base64
import hashlib
import json
import pathlib
import shutil
import subprocess
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
COMMIT = "1a71df0f381cefde80bf912b723de6f9831bc177"
evidence = ROOT / "share-model-reference-evidence"
evidence.mkdir(exist_ok=True)
manifest = {"commit": COMMIT, "sources": {}, "scope": "Identical unchanged upstream pure behavior cases against upstream and production model. Upstream ToolFoldPlanner is a fixture input generator; Ze fold integration is NOT established here."}
def fetch(path):
    target = evidence / pathlib.Path(path).name
    if not target.exists():
        data = json.loads(subprocess.check_output(["gh", "api", f"repos/OpenMinis/OpenMinis/contents/{path}?ref={COMMIT}"], timeout=45))
        target.write_bytes(base64.b64decode(data["content"]))
    raw = target.read_bytes()
    manifest["sources"][path] = {"gitBlob": hashlib.sha1(b"blob " + str(len(raw)).encode() + b"\0" + raw).hexdigest(), "sha256": hashlib.sha256(raw).hexdigest()}
    return raw.decode("utf-8")
upstream = fetch("src/ios/Views/Chat/ChatShareModel.swift")
test = fetch("src/ios/MinisTests/Standalone/ChatShareModelTests.swift")
planner = fetch("src/ios/Agent/MessageList/ToolFoldPlanner.swift").split("// END ToolFoldPlanner", 1)[0]
cases = test.split('let tests = #"""', 1)[1].split('"""#', 1)[0]
# Swift 6.0 exhausts its type-check budget on this upstream mixed numeric
# expression. Type its numeric terms without changing the assertion; both
# reference and production execute the same adapted cases.
cases = cases.replace("8 * 2 + (60 + 100 + 200) + 18 * CGFloat(max(3 - 2, 0)) + 8",
                      "CGFloat(16) + CGFloat(360) + CGFloat(18) * CGFloat(max(3 - 2, 0)) + CGFloat(8)")
manifest["testCompatibility"] = "Explicit CGFloat terms in one unchanged layout arithmetic assertion for Swift 6.0 type checking; same cases on both models."
assert "exit(fails == 0 ? 0 : 1)" in cases
production = (ROOT / "Views/Chat/SessionExport/ChatShareModel.swift").read_text(encoding="utf-8")
manifest["productionSHA256"] = hashlib.sha256((ROOT / "Views/Chat/SessionExport/ChatShareModel.swift").read_bytes()).hexdigest()
(evidence / "sources.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
compiler = shutil.which("swiftc")
if not compiler:
    print("SKIP: Swift compiler absent; fetched original behavior cases, execute on macOS CI")
else:
    with tempfile.TemporaryDirectory(prefix="ze-share-model-reference-") as tmp:
        directory = pathlib.Path(tmp)
        main = directory / "main.swift"
        main.write_text("import Foundation\nimport CoreGraphics\n" + cases, encoding="utf-8")
        model = directory / "model.swift"
        for label, source in [("reference", upstream), ("production", production)]:
            model.write_text(source + "\n" + planner, encoding="utf-8")
            binary = directory / label
            subprocess.run([compiler, str(model), str(main), "-o", str(binary)], check=True)
            result = subprocess.run([str(binary)], capture_output=True, text=True)
            (evidence / (label + "-behavior.log")).write_text(result.stdout + result.stderr, encoding="utf-8")
            print(label + ": " + str(result.stdout.count("RESULT pass")) + " upstream behavioral cases")
            result.check_returncode()
    print("PASS: original sharing behavior cases on reference and production")
