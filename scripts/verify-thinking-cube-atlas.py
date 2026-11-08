#!/usr/bin/env python3
"""Check the committed reference mask, sampled frames and memory budget using stdlib."""
from pathlib import Path
import hashlib
import json
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]
asset = ROOT / 'Assets.xcassets/ThinkingCubeAtlas.imageset/thinking-cube-atlas.png'
manifest = json.loads((ROOT / 'scripts/thinking-cube-atlas.json').read_text(encoding='utf-8'))
data = asset.read_bytes()
assert hashlib.sha256(data).hexdigest() == manifest['atlasSHA256'], 'Atlas checksum differs'
assert data[:8] == b'\x89PNG\r\n\x1a\n'
offset = 8
compressed = bytearray()
while offset < len(data):
    size = struct.unpack('>I', data[offset:offset + 4])[0]
    name = data[offset + 4:offset + 8]
    value = data[offset + 8:offset + 8 + size]
    if name == b'IHDR':
        width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', value)
    elif name == b'IDAT':
        compressed.extend(value)
    offset += 12 + size
assert (width, height, depth, color, interlace) == (448, 560, 8, 6, 0)
raw = zlib.decompress(compressed)
stride = width * 4
rows = []
last = bytearray(stride)
for y in range(height):
    start = y * (stride + 1)
    method = raw[start]
    row = bytearray(raw[start + 1:start + 1 + stride])
    for x in range(stride):
        left = row[x - 4] if x >= 4 else 0
        up = last[x]
        corner = last[x - 4] if x >= 4 else 0
        if method == 1:
            predictor = left
        elif method == 2:
            predictor = up
        elif method == 3:
            predictor = (left + up) // 2
        elif method == 4:
            p = left + up - corner
            distances = (abs(p - left), abs(p - up), abs(p - corner))
            predictor = (left, up, corner)[distances.index(min(distances))]
        else:
            assert method == 0, method
            predictor = 0
        row[x] = (row[x] + predictor) & 255
    assert not any(row[0::4]) and not any(row[1::4]) and not any(row[2::4]), 'Mask contains color pixels'
    rows.append(bytes(row[3::4]))
    last = row

assert (manifest['framesPerSecond'], manifest['introFrameCount'], manifest['loopFrameCount'],
        manifest['frameCount'], manifest['tileSide'], manifest['atlasColumns']) == (60, 12, 62, 74, 56, 8)
frames = []
for index in range(80):
    x, y = index % 8 * 56, index // 8 * 56
    frame = b''.join(row[x:x + 56] for row in rows[y:y + 56])
    if index < 74:
        assert max(frame) > 40, ('Empty frame', index)
        assert not any(frame[:112] + frame[-112:]), ('Top/bottom glyph clipping', index)
        assert all(not any(frame[row * 56:row * 56 + 2] + frame[row * 56 + 54:row * 56 + 56])
                   for row in range(56)), ('Side glyph clipping', index)
        frames.append(frame)
    else:
        assert not any(frame), ('Unassigned atlas tile contains data', index)
for source_index, checksum in enumerate(manifest['sourceFrameAlphaSHA256']):
    assert hashlib.sha256(frames[source_index * 2]).hexdigest() == checksum, ('Reference sample differs', source_index)
assert len(manifest['sourceFrameAlphaSHA256']) == 35
seam = sum(abs(a - b) for a, b in zip(frames[-1], frames[12])) / (56 * 56)
assert seam < 1, ('Loop join has a visible jump', seam)
assert manifest['decodedAtlasBytes'] + 74 * 56 * 56 * 4 <= 2 * 1024 * 1024
print(json.dumps({'success': True, 'referenceSamples': 35, 'nativeFrames': 74,
                  'loopSeamMeanAlphaDifference': seam,
                  'decodedAtlasAndFramesBytes': 1931776,
                  'atlasSHA256': manifest['atlasSHA256']}, indent=2))
