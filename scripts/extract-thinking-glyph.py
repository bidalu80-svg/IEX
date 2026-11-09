#!/usr/bin/env python3
"""Extract the complete production thinking row, including its real label motion."""
from pathlib import Path
import hashlib
import json
import sys

root = Path(__file__).resolve().parents[1]
source = root / 'Views/Chat/AssistantBlockView.swift'
text = source.read_text(encoding='utf-8')
start = text.index('// MARK: - Typing Indicator')
end = text.index('// MARK: - Thinking Level Sheet', start)
indicator = text[start:end]
shimmer_start = text.index('private enum ChatShimmerStyle {')
shimmer_end = text.index('\n}', shimmer_start) + 2
palette_source = root / 'Views/Chat/AIChatView.swift'
palette = palette_source.read_text(encoding='utf-8')
palette_start = palette.index('enum ChatColors {')
palette_end = palette.index('\n}', palette_start) + 2
output = Path(sys.argv[1])
output.parent.mkdir(parents=True, exist_ok=True)
output.write_text('import SwiftUI\nimport UIKit\n\n' +
                  palette[palette_start:palette_end] + '\n\n' +
                  text[shimmer_start:shimmer_end] + '\n\n' + indicator + '\n' +
                  (root / 'scripts/ThinkingGlyphUIHarness.swift').read_text(encoding='utf-8'),
                  encoding='utf-8')
output.with_suffix('.sources.json').write_text(json.dumps({
    'source': str(source.relative_to(root)),
    'sourceSHA256': hashlib.sha256(source.read_bytes()).hexdigest(),
    'paletteSource': str(palette_source.relative_to(root)),
    'paletteSourceSHA256': hashlib.sha256(palette_source.read_bytes()).hexdigest(),
    'extraction': 'Unmodified production frame sampler, cache, Canvas, complete TypingIndicatorFrame and TypingIndicator, with the production palette and shimmer timing',
    'scope': 'iOS16 compilation, deterministic glyph and full-row entrance frames, and simulator snapshots; no physical-device FPS assertion',
}, indent=2), encoding='utf-8')
print(output)
