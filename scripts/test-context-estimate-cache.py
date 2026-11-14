#!/usr/bin/env python3
"""Execute production estimate/cache declarations against mutations and a legacy oracle.

The history selection and image tokenizer are deterministic fixtures. Their
production algorithms are unchanged; this test checks cache invalidation and
the counting formula, including Swift value-type nested writeback semantics.
"""
import argparse
from pathlib import Path
import subprocess
import tempfile
import shutil

ROOT = Path(__file__).resolve().parents[1]
parser = argparse.ArgumentParser()
parser.add_argument("--prepare-only", type=Path)
args = parser.parse_args()
model = (ROOT / "Agent/Chat/AIChatViewModel.swift").read_text(encoding="utf-8")
offload = (ROOT / "Agent/Chat/AIChatViewModel+Offloading.swift").read_text(encoding="utf-8")
provider = (ROOT / "Providers/AgentProvider.swift").read_text(encoding="utf-8")
parts = provider.split("enum AgentContentPart:", 1)[1].split("\n}\n", 1)[0]
parts = "enum AgentContentPart:" + parts + "\n}\n"
history = model.split("    var agentHistory:", 1)[1].split("\n    /// Dynamic,", 1)[0]
history = "    var agentHistory:" + history
marker = model.split("    var cachedLatestMarker:", 1)[1].split("\n    /// The session's persisted", 1)[0]
marker = "    var cachedLatestMarker:" + marker
estimate = offload.split("    func estimateContextTokens(", 1)[1].split("    /// - `force`:", 1)[0]
estimate = "    func estimateContextTokens(" + estimate
fixture = r'''
import Foundation
struct SilentLogger { func info(_ text: String) {} }
let logger = SilentLogger()
final class BPETokenizer {
    static let shared = BPETokenizer()
    func countImageTokens(_ data: Data) -> Int { 85 + data.count / 10 }
}
struct AgentMessage {
    enum Role { case user, assistant }
    var role: Role
    var parts: [AgentContentPart]
    var dbMessageId: String?
}
struct CompactMarker { var summary: String; var boundary: String }
final class Fixture {
    HISTORY
    MARKER
    var slices = 0
    func effectiveAgentHistory() -> [AgentMessage] {
        slices += 1
        guard let marker = cachedLatestMarker,
              let start = agentHistory.firstIndex(where: { $0.dbMessageId == marker.boundary }) else { return agentHistory }
        return [AgentMessage(role: .user, parts: [.text(marker.summary)])] + Array(agentHistory[start...])
    }
    ESTIMATE
    func uncachedOracle() -> Int {
        var chars = 0, images = 0
        for msg in effectiveAgentHistory() {
            for part in msg.parts {
                switch part {
                case .text(let text): chars += text.count
                case .toolUse(_, _, let input):
                    if let data = try? JSONSerialization.data(withJSONObject: input) { chars += data.count }
                case .toolResult(_, _, let content, _, let data, _, _, _):
                    chars += content.count
                    if let data { images += BPETokenizer.shared.countImageTokens(data) }
                case .imageData(let data, _, _): images += BPETokenizer.shared.countImageTokens(data)
                }
            }
        }
        return Int(Double(chars) / 3.5) + images
    }
}
let f = Fixture()
var checks = 0
func check(_ name: String) {
    precondition(f.cachedContextTokenEstimate == nil, "stale estimate after \(name)")
    let expected = f.uncachedOracle()
    precondition(f.estimateContextTokens() == expected, "formula changed: \(name)")
    let count = f.slices
    for _ in 0..<100 { precondition(f.estimateContextTokens() == expected) }
    precondition(f.slices == count, "cache hit traversed history: \(name)")
    checks += 1
}
check("empty")
f.agentHistory = (0..<200).map { i in
    AgentMessage(role: i.isMultiple(of: 2) ? .user : .assistant,
        parts: [.text(String(repeating: "中文 é 👩‍👧 code ", count: 200)),
                .toolUse(id: "t\(i)", name: "tool", input: ["number": i, "nested": ["a", "b"]]),
                .toolResult(id: "t\(i)", name: "tool", content: "result", isError: false, imageData: Data(repeating: 1, count: 100)),
                .imageData(data: Data(repeating: 2, count: 200), mimeType: "image/png")], dbMessageId: "\(i)")
}
check("long history")
f.agentHistory[0].parts[0] = .text("edited")
check("nested part edit")
f.agentHistory[0].parts.append(.text("appended"))
check("nested part append")
f.agentHistory[1].dbMessageId = "edited-id"
check("persisted boundary identity")
f.cachedLatestMarker = CompactMarker(summary: "summary one", boundary: "100")
check("compaction")
f.cachedLatestMarker?.summary = "summary with a changed size"
check("nested marker edit")
f.cachedLatestMarker = CompactMarker(summary: "summary two", boundary: "edited-id")
check("marker replacement")
f.agentHistory[1].dbMessageId = nil
check("unresolved compact boundary")
f.cachedLatestMarker = nil
check("revert compaction")
f.agentHistory.removeLast(50)
check("delete/retry")
f.agentHistory.append(AgentMessage(role: .user, parts: [.text("next turn")]))
check("append")
f.agentHistory.removeAll()
check("clear/session replacement")
print("PASS: \(checks) mutation scenarios; 100 warm cache hits per scenario without history traversal")
'''
source = parts + fixture.replace("HISTORY", history).replace("MARKER", marker).replace("ESTIMATE", estimate)
# Swift declarations may precede imports, but keep Foundation at the top too.
source = "import Foundation\n" + source
if args.prepare_only:
    args.prepare_only.write_text(source, encoding="utf-8")
    print(args.prepare_only)
else:
    compiler = shutil.which("swiftc")
    if not compiler:
        raise SystemExit("swiftc is required; use --prepare-only locally and run the executable checks on macOS")
    with tempfile.TemporaryDirectory(prefix="ze-context-cache-") as directory:
        path = Path(directory) / "main.swift"
        path.write_text(source, encoding="utf-8")
        executable = Path(directory) / "checks"
        subprocess.run([compiler, str(path), "-o", str(executable)], check=True)
        subprocess.run([str(executable)], check=True)
