#!/usr/bin/env python3
"""Validate app assets and emit evidence; runtime tests use the complete app."""
from pathlib import Path
import hashlib, json, os, struct, sys
root = Path(__file__).resolve().parents[1]
out = Path(sys.argv[1]); out.mkdir(parents=True, exist_ok=True)
original = json.loads((root / 'scripts/soul-avatar-assets.json').read_text(encoding='utf-8'))
refined = json.loads((root / 'scripts/soul-laptop-refinement.json').read_text(encoding='utf-8'))
assets = {}
for key, entry in original['assets'].items():
    catalog = root / 'Assets.xcassets' / ('SoulAvatar-main.imageset' if key == 'main' else f'SoulAvatar-{key}.dataset')
    contents = json.loads((catalog / 'Contents.json').read_text(encoding='utf-8'))
    filename = contents.get('images', contents.get('data'))[0]['filename']
    data = (catalog / filename).read_bytes()
    digest = hashlib.sha256(data).hexdigest()
    expected = refined['outputs'][key.split('-')[1]] if key.startswith('working-') else entry['source_sha256']
    assert digest == expected, f'Unexpected avatar asset: {key}'
    if key == 'main':
        width, height, depth, color = struct.unpack('>IIBB', data[16:26])
        assert min(width, height) >= 1024 and color == 6, 'Expected large RGBA PNG'
    else:
        assert data[4:8] == b'ftyp', f'Expected MP4: {key}'
    assets[key] = {'sha256': digest, 'bytes': len(data), 'source': 'laptop refinement' if key.startswith('working-') else 'user archive'}
source_files = ['Agent/Session/SoulStore.swift', 'Views/Chat/AIChatView.swift',
                'Views/Chat/SessionExport/ConversationChatVerification.swift',
                'scripts/ChatLayoutApplicationUITests.swift']
report = {'assets': assets, 'sources': {p: hashlib.sha256((root / p).read_bytes()).hexdigest() for p in source_files},
          'scope': 'Resource integrity only. Runtime verification uses the complete Ze application on iOS 26.'}
(out / 'sources.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
source = (root / source_files[0]).read_text(encoding='utf-8')
policy = source.split('enum SoulAvatarMotion:', 1)[1].split('\n@MainActor', 1)[0]
(Path(os.environ.get('RUNNER_TEMP', out)) / 'SoulAvatarMotion.swift').write_text('enum SoulAvatarMotion:' + policy, encoding='utf-8')
print(f'PASS: {len(assets)} actual application assets match the supplied archive/refinement manifest')
