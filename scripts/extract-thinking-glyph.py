#!/usr/bin/env python3
"""Extract the current production thinking glyph without copying its drawing code."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[1]
source = root / 'Views/Chat/AssistantBlockView.swift'
text = source.read_text(encoding='utf-8')
start = text.index('// MARK: - Typing Indicator')
end = text.index('\nstruct TypingIndicator:', start)
glyph = text[start:end]
output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('import SwiftUI\nimport UIKit\n\n' + glyph + '\n' +
                  (root / 'scripts/ThinkingGlyphUIHarness.swift').read_text(encoding='utf-8'),
                  encoding='utf-8')
output.with_suffix('.sources.json').write_text(json.dumps({
    'source': str(source.relative_to(root)),
    'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'extraction': 'Unmodified production animation engine, deterministic frame and TimelineView glyph',
    'scope': 'iOS16 compilation and deterministic rendered frames; no physical-device FPS assertion',
}, indent=2), encoding='utf-8')
print(output)
