#!/usr/bin/env python3
"""Independently verify source restoration, local closure and continuous pose.

The committed check needs only Python stdlib. Optional --source verifies the
original clip as well, using the offline author's imageio/Pillow dependencies.
Endpoint equality checks local closure only; fidelity uses all 56 source masks.
"""
import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import struct
import zlib

ROOT = Path(__file__).resolve().parents[1]


def read_alpha_png(path):
    data = path.read_bytes()
    assert data[:8] == b'\x89PNG\r\n\x1a\n', 'Not a PNG atlas'
    offset, compressed = 8, bytearray()
    while offset < len(data):
        size = struct.unpack('>I', data[offset:offset + 4])[0]
        name = data[offset + 4:offset + 8]
        value = data[offset + 8:offset + 8 + size]
        if name == b'IHDR':
            width, height, depth, color, _, _, interlace = struct.unpack('>IIBBBBB', value)
        elif name == b'IDAT':
            compressed.extend(value)
        offset += 12 + size
    assert (depth, color, interlace) == (8, 6, 0), 'Expected un-interlaced RGBA8'
    raw, rows = zlib.decompress(compressed), []
    stride, previous = width * 4, bytearray(width * 4)
    for y in range(height):
        start = y * (stride + 1)
        method = raw[start]
        row = bytearray(raw[start + 1:start + 1 + stride])
        for x in range(stride):
            left = row[x - 4] if x >= 4 else 0
            up = previous[x]
            corner = previous[x - 4] if x >= 4 else 0
            if method == 1:
                predictor = left
            elif method == 2:
                predictor = up
            elif method == 3:
                predictor = (left + up) // 2
            elif method == 4:
                p = left + up - corner
                distances = abs(p - left), abs(p - up), abs(p - corner)
                predictor = (left, up, corner)[distances.index(min(distances))]
            else:
                assert method == 0, method
                predictor = 0
            row[x] = (row[x] + predictor) & 255
        assert not any(row[0::4]) and not any(row[1::4]) and not any(row[2::4]), 'Non-neutral atlas pixel'
        rows.append(bytes(row[3::4]))
        previous = row
    return width, height, rows


def scale_at(pose, source_frame):
    keys = pose['scaleKeyframes']
    if source_frame <= keys[0][0]:
        return keys[0][1]
    for (left, a), (right, b) in zip(keys, keys[1:]):
        if source_frame <= right:
            t = (source_frame - left) / (right - left)
            if left == 52:
                t = t * t * (3 - 2 * t)
            return a + (b - a) * t
    return keys[-1][1]


def restore_bilinear(alpha, source_frame, side, pose):
    """Independent raster restore: inverse rotation/scale then bilinear sample.

    This intentionally does not use the author's OpenCV warp or interpolation.
    Source and restored rasters are compared in the original video coordinates.
    """
    angle = math.radians(pose['openCVAngleDegreesPerSourceFrame'] *
                         (source_frame - pose['sourceFrameOrigin']))
    cosine, sine = math.cos(angle), math.sin(angle)
    scale = scale_at(pose, source_frame)
    px, py = pose['pivotPixels']
    output = bytearray(side * side)

    def pixel(x, y):
        return alpha[y * side + x] if 0 <= x < side and 0 <= y < side else 0

    for y in range(side):
        for x in range(side):
            dx, dy = x - px, y - py
            sx = (cosine * dx - sine * dy) / scale + px
            sy = (sine * dx + cosine * dy) / scale + py
            left, top = math.floor(sx), math.floor(sy)
            fx, fy = sx - left, sy - top
            value = (pixel(left, top) * (1 - fx) * (1 - fy) +
                     pixel(left + 1, top) * fx * (1 - fy) +
                     pixel(left, top + 1) * (1 - fx) * fy +
                     pixel(left + 1, top + 1) * fx * fy)
            output[y * side + x] = min(255, max(0, round(value)))
    return bytes(output)


def mae(a, b):
    assert len(a) == len(b)
    return sum(abs(x - y) for x, y in zip(a, b)) / len(a)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    args = parser.parse_args()
    asset = ROOT / 'Assets.xcassets/ThinkingCubeAtlas.imageset/thinking-cube-atlas.png'
    manifest = json.loads((ROOT / 'scripts/thinking-cube-atlas.json').read_text(encoding='utf-8'))
    assert hashlib.sha256(asset.read_bytes()).hexdigest() == manifest['atlasSHA256'], 'Atlas checksum differs'
    width, height, rows = read_alpha_png(asset)
    side, columns, count = manifest['tileSide'], manifest['atlasColumns'], manifest['frameCount']
    intro, loop, fps = manifest['introFrameCount'], manifest['loopFrameCount'], manifest['framesPerSecond']
    atlas_rows = math.ceil(count / columns)
    assert (width, height) == (columns * side, atlas_rows * side)
    assert atlas_rows == manifest['atlasRows'] and count == intro + loop
    assert (fps, intro, loop, count, side, columns) == (60, 16, 108, 124, 56, 8)
    assert manifest['schemaVersion'] == 2
    assert manifest['sourceTotalFrameCount'] == 90 and manifest['sourceSceneChangeFrame'] == 56
    assert manifest['sourceWaitingFramesInclusive'] == [0, 55]
    frames = []
    for index in range(atlas_rows * columns):
        x, y = index % columns * side, index // columns * side
        frame = b''.join(row[x:x + side] for row in rows[y:y + side])
        if index < count:
            assert max(frame) > 40, ('Empty atlas frame', index)
            assert not any(frame[:2 * side] + frame[-2 * side:]), ('Vertical clipping', index)
            assert all(not any(frame[row * side:row * side + 2] +
                               frame[row * side + side - 2:(row + 1) * side])
                       for row in range(side)), ('Horizontal clipping', index)
            frames.append(frame)
        else:
            assert not any(frame), ('Unassigned tile has pixels', index)
    reference_data = zlib.decompress(base64.b64decode(manifest['sourceMasksZlibBase64']))
    assert len(reference_data) == 56 * side * side
    sources = [reference_data[index * side * side:(index + 1) * side * side] for index in range(56)]
    assert len(manifest['sourceFrameAlphaSHA256']) == len(manifest['sourceCanonicalAlphaSHA256']) == 56
    assert manifest['sourceCanonicalAtlasIndices'] == [index * 2 for index in range(56)]
    for index, source in enumerate(sources):
        assert hashlib.sha256(source).hexdigest() == manifest['sourceFrameAlphaSHA256'][index], ('Source evidence differs', index)
        assert hashlib.sha256(frames[index * 2]).hexdigest() == manifest['sourceCanonicalAlphaSHA256'][index], ('Canonical sample differs', index)
    first_ink = sum(value > 40 for value in sources[0])
    settled_ink = sum(value > 40 for value in sources[8])
    assert 1 <= first_ink <= 25 and settled_ink > first_ink * 5, 'Reference must start at a point before expansion'
    pose = manifest['globalPose']
    assert pose['pivotPixels'] == [28.5, 27.5] and pose['swiftRotationSign'] == -1
    assert pose['sourceFramesPerSecond'] == manifest['sourceFPS'] == 30
    assert pose['openCVAngleDegreesPerSourceFrame'] > 0
    errors = [mae(source, restore_bilinear(frames[index * 2], index, side, pose))
              for index, source in enumerate(sources)]
    tolerance = manifest['reconstructionMetrics']['maximumPermittedIndependentBilinearMAE']
    assert max(errors) <= tolerance, ('Independent source restoration differs', max(errors), tolerance)
    # Endpoint equality is a local-loop property. It is not used as a claim
    # that the reconstructed tail was present in the supplied reference.
    local_join = mae(frames[-1], frames[intro])
    assert local_join < 1, ('Local layer endpoint does not close', local_join)
    tail = manifest['reconstructedTail']
    assert tail['firstAtlasIndex'] == 111 and tail['lastAtlasIndex'] == 123
    assert tail['sourceFrom'] == 55 and 'Reconstructed' in tail['scope']
    boundaries = []
    for repetition in range(8):
        tick = intro + (repetition + 1) * loop
        before_source = (tick - 1) / fps * manifest['sourceFPS']
        after_source = tick / fps * manifest['sourceFPS']
        before = restore_bilinear(frames[-1], before_source, side, pose)
        after = restore_bilinear(frames[intro], after_source, side, pose)
        angular_step = (after_source - before_source) * pose['openCVAngleDegreesPerSourceFrame']
        assert abs(angular_step - pose['openCVAngleDegreesPerSourceFrame'] / 2) < 1e-10
        error = mae(before, after)
        assert error < 1, ('Global pose jumps at local wrap', tick, error)
        boundaries.append({'tick': tick, 'worldAlphaMAE': error, 'globalAngleStepDegrees': angular_step})
    first_pose = restore_bilinear(frames[intro], 8, side, pose)
    after_loop_pose = restore_bilinear(frames[intro], 8 + loop / fps * 30, side, pose)
    assert mae(first_pose, after_loop_pose) > 1, 'Global pose must advance while local layers loop'
    decoded_bytes = width * height * 4 + count * side * side * 4
    assert decoded_bytes == manifest['decodedAtlasAndFramesBytes']
    assert decoded_bytes <= manifest['decodedMemoryBudgetBytes'] == 4 * 1024 * 1024
    source_verified = False
    if args.source:
        import imageio.v2 as imageio
        from PIL import Image
        assert hashlib.sha256(args.source.read_bytes()).hexdigest() == manifest['sourceSHA256'], 'Original clip checksum differs'
        reader = imageio.get_reader(str(args.source), 'ffmpeg')
        originals = [frame for frame in reader]
        reader.close()
        assert len(originals) == manifest['sourceTotalFrameCount']
        left, top, right, bottom = manifest['crop']
        for index, original in enumerate(originals[:56]):
            gray = Image.fromarray(original).convert('L').crop((left, top, right, bottom))
            alpha = bytes(255 - value if 255 - value > 3 else 0 for value in gray.tobytes())
            assert alpha == sources[index], ('Persisted source evidence differs from video', index)
        changed = Image.fromarray(originals[manifest['sourceSceneChangeFrame']]).convert('L').crop(
            (left, top, right, bottom))
        assert sum(255 - value > 40 for value in changed.tobytes()) == 0, 'Scene change must end the waiting cube'
        source_verified = True
    print(json.dumps({'success': True, 'referenceSamples': 56, 'nativeFrames': count,
                      'originalClipVerified': source_verified,
                      'independentBilinearMeanFrameAlphaByteError': sum(errors) / len(errors),
                      'independentBilinearMaximumFrameAlphaByteError': max(errors),
                      'perSourceFrameAlphaByteError': errors,
                      'localEndpointAlphaByteError': local_join,
                      'localEndpointMeaning': 'Authored local closure only; fidelity measured independently against all source masks',
                      'continuousGlobalBoundaries': boundaries,
                      'decodedAtlasAndFramesBytes': decoded_bytes,
                      'atlasSHA256': manifest['atlasSHA256'], 'scope': manifest['scope']}, indent=2))


if __name__ == '__main__':
    main()
