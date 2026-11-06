#!/usr/bin/env python3
"""Compile the shipping child card views unchanged, alongside a simulator harness."""
import hashlib
import json
import pathlib
import sys
from search_harness_support import search_support

root = pathlib.Path(__file__).resolve().parents[1]
views_path = root / "Views/Chat/ZeSubAgentViews.swift"
models_path = root / "Agent/Chat/ZeSubAgentCoordinator.swift"
views = views_path.read_text(encoding="utf-8")
models = models_path.read_text(encoding="utf-8")

def section(source, start, end):
    begin = source.index(start)
    finish = source.index(end, begin)
    return source[begin:finish]

parts = [
    search_support(root),
    "import SwiftUI\nimport UIKit\nimport Foundation\n",
    section(models, "enum ZeSubAgentStatus:", "/// Owns a bounded child-agent tree"),
    section(views, "enum ZeSubAgentTheme {", "/// Compact, native iOS dock"),
    section(views, "enum ZeSubAgentPresentation {", "struct ZeSubAgentDetailView:"),
    section(views, "private struct ZeSubAgentSection<", "private struct ZeSubAgentCollapsibleText:"),
    section(views, "private struct ZeSubAgentRunStats:", "private struct ZeSubAgentImagePreview:"),
    (root / "scripts/SubAgentUIHarness.swift").read_text(encoding="utf-8"),
]
destination = pathlib.Path(sys.argv[1])
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(parts), encoding="utf-8")
manifest = {
    "sourceSHA256": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [views_path, models_path]},
    "extraction": "Unmodified declarations; configuration lookup fixture only; no replacement card views",
}
destination.with_suffix(".sources.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(destination)
