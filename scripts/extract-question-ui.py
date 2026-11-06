#!/usr/bin/env python3
"""Build a simulator harness from the current production question card declarations."""
import hashlib
import json
import pathlib
import sys
from search_harness_support import search_support

root = pathlib.Path(__file__).resolve().parents[1]
views_path = root / "Views/Chat/AssistantBlockView.swift"
state_path = root / "Agent/Chat/ChatLifecycleSupport.swift"
speech_path = root / "Agent/Speech/SpeechRecognitionManager.swift"
views = views_path.read_text(encoding="utf-8")
state = state_path.read_text(encoding="utf-8")
palette = (root / "Views/Chat/AIChatView.swift").read_text(encoding="utf-8")
palette_begin = palette.index("enum ChatColors {")
palette_end = palette.index("\n}", palette_begin) + 2
begin = views.index("enum QuestionCardTheme {")
end = views.index("// MARK: - Thinking Block View", begin)
models_begin = state.index("struct QuestionCardQuestion:")
parts = [
    "import SwiftUI\nimport UIKit\nimport Foundation\nimport Combine\nimport UserNotifications\n",
    state[models_begin:],
    search_support(root, question=True),
    palette[palette_begin:palette_end],
    views[begin:end],
    speech_path.read_text(encoding="utf-8"),
    (root / "scripts/QuestionCardUIHarness.swift").read_text(encoding="utf-8"),
]
destination = pathlib.Path(sys.argv[1])
destination.parent.mkdir(parents=True, exist_ok=True)
destination.write_text("\n".join(parts), encoding="utf-8")
manifest = {
    "sourceSHA256": {str(p.relative_to(root)): hashlib.sha256(p.read_bytes()).hexdigest()
                     for p in [views_path, state_path, speech_path]},
    "extraction": "Unmodified production card views, question state, coordinator and speech manager; message/log integration fixtures only",
}
destination.with_suffix(".sources.json").write_text(json.dumps(manifest, indent=2), encoding="utf-8")
print(destination)
