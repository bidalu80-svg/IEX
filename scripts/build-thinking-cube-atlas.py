#!/usr/bin/env python3
"""Author local reference motion separately from its continuous global pose.

Offline only: pip install imageio imageio-ffmpeg opencv-python-headless pillow.
Every observed waiting frame is retained. The final partially observed layer
turn is completed offline; no video decoder or optical flow runs on the phone.
"""
import argparse
import base64
import hashlib
import json
import math
from pathlib import Path
import zlib

import cv2
import imageio.v2 as imageio
import numpy as np
from PIL import Image, ImageDraw

FPS, SOURCE_FPS, SIDE, COLUMNS = 60, 30, 56, 8
INTRO, LOOP, COUNT = 16, 108, 124
PIVOT, RATE = (28.5, 27.5), 0.919341504573822
SCALE_KEYS = [(8, 1.0), (17, 1.0036402940750122),
              (26, 0.9911999388661918), (35, 0.9646904525861668),
              (43, 0.9361779693449992), (52, 0.9070229325033577), (61, 0.9)]
MEMORY_BUDGET = 4 * 1024 * 1024


def scale_at(source_frame):
    if source_frame <= SCALE_KEYS[0][0]:
        return SCALE_KEYS[0][1]
    for (left, a), (right, b) in zip(SCALE_KEYS, SCALE_KEYS[1:]):
        if source_frame <= right:
            t = (source_frame - left) / (right - left)
            if left == 52:
                t = t * t * (3 - 2 * t)
            return a + (b - a) * t
    return SCALE_KEYS[-1][1]


def pose_at(source_frame):
    return cv2.getRotationMatrix2D(PIVOT, RATE * (source_frame - 8), scale_at(source_frame))


def normalize(alpha, source_frame):
    return cv2.warpAffine(alpha, pose_at(source_frame), (SIDE, SIDE),
                          flags=cv2.INTER_CUBIC | cv2.WARP_INVERSE_MAP,
                          borderMode=cv2.BORDER_CONSTANT)


def restore(alpha, source_frame):
    return cv2.warpAffine(alpha, pose_at(source_frame), (SIDE, SIDE),
                          flags=cv2.INTER_CUBIC, borderMode=cv2.BORDER_CONSTANT)


def interpolate(left, right, fraction):
    if fraction <= 0:
        return left.copy()
    if fraction >= 1:
        return right.copy()
    a = cv2.resize(left, (SIDE * 4, SIDE * 4), interpolation=cv2.INTER_CUBIC)
    b = cv2.resize(right, (SIDE * 4, SIDE * 4), interpolation=cv2.INTER_CUBIC)
    ab = cv2.calcOpticalFlowFarneback(a, b, None, .5, 4, 25, 5, 7, 1.5, 0)
    ba = cv2.calcOpticalFlowFarneback(b, a, None, .5, 4, 25, 5, 7, 1.5, 0)
    y, x = np.mgrid[:a.shape[0], :a.shape[1]].astype(np.float32)
    first = cv2.remap(a, x - ab[:, :, 0] * fraction, y - ab[:, :, 1] * fraction,
                      cv2.INTER_CUBIC, borderMode=cv2.BORDER_CONSTANT)
    second = cv2.remap(b, x - ba[:, :, 0] * (1 - fraction),
                       y - ba[:, :, 1] * (1 - fraction), cv2.INTER_CUBIC,
                       borderMode=cv2.BORDER_CONSTANT)
    mixed = first.astype(np.float32) * (1 - fraction) + second.astype(np.float32) * fraction
    return cv2.resize(np.uint8(np.clip(mixed, 0, 255)), (SIDE, SIDE), interpolation=cv2.INTER_AREA)


def frame_index(elapsed):
    index = max(0, int(math.floor(elapsed * FPS + 1e-8)))
    return index if index < INTRO else INTRO + (index - INTRO) % LOOP


def render_at(frames, elapsed):
    return restore(frames[frame_index(elapsed)], elapsed * SOURCE_FPS)


def alpha_error(a, b):
    error = np.abs(a.astype(np.float32) - b.astype(np.float32))
    return {'meanAbsoluteAlphaByteError': float(error.mean()),
            'rootMeanSquareAlphaByteError': float(np.sqrt((error * error).mean())),
            'maximumAlphaByteError': int(error.max())}


def previews(output, source_masks, frames):
    output.mkdir(parents=True, exist_ok=True)
    with imageio.get_writer(str(output / 'reference-restoration-30fps.mp4'), fps=30,
                            codec='libx264', quality=9) as video:
        for index, source in enumerate(source_masks):
            image = Image.new('RGB', (672, 384), 'white')
            draw = ImageDraw.Draw(image)
            draw.text((8, 8), f'Source F{index:02d} t={index / 30:.3f}s', fill='black')
            draw.text((344, 8), 'Atlas + restored global pose', fill='black')
            for x, mask in [(0, source), (336, restore(frames[index * 2], index))]:
                tile = Image.fromarray(255 - mask).convert('RGB')
                image.paste(tile.resize((336, 336), Image.Resampling.NEAREST), (x, 32))
            video.append_data(np.asarray(image))
    with imageio.get_writer(str(output / 'continuous-global-motion-15s.mp4'), fps=60,
                            codec='libx264', quality=9) as video:
        for tick in range(15 * FPS):
            elapsed = tick / FPS
            image = Image.new('RGB', (448, 448), 'white')
            draw = ImageDraw.Draw(image)
            draw.text((8, 8), f't={elapsed:.3f}s local frame={frame_index(elapsed)}', fill='black')
            draw.text((8, 26), f'global angle={-RATE * (elapsed * 30 - 8):.2f} deg', fill='black')
            draw.text((8, 44), 'Continuation after source end is reconstructed', fill='black')
            tile = Image.fromarray(255 - render_at(frames, elapsed)).convert('RGB')
            image.paste(tile.resize((336, 336), Image.Resampling.NEAREST), (56, 88))
            video.append_data(np.asarray(image))
    sheet = Image.new('RGB', (8 * 168, 7 * 192), 'white')
    draw = ImageDraw.Draw(sheet)
    for index in range(56):
        x, y = index % 8 * 168, index // 8 * 192
        draw.text((x + 4, y + 4), f'F{index:02d}: reconstructed', fill='black')
        tile = Image.fromarray(255 - restore(frames[index * 2], index)).convert('RGB')
        sheet.paste(tile.resize((168, 168), Image.Resampling.NEAREST), (x, y + 24))
    sheet.save(output / 'restored-source-frames-00-55.png')
    times = [0, .1, .2, .5, 1, 1.8, 2.05, 2.066666667, 3.85, 3.866666667, 7, 13, 14.9]
    for index, elapsed in enumerate(times):
        Image.fromarray(255 - render_at(frames, elapsed)).resize(
            (336, 336), Image.Resampling.NEAREST).save(output / f'continuous-sample-{index:02d}-{elapsed:.3f}s.png')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'Assets.xcassets/ThinkingCubeAtlas.imageset')
    parser.add_argument('--preview', type=Path)
    args = parser.parse_args()
    reader = imageio.get_reader(str(args.input), 'ffmpeg')
    metadata = reader.get_meta_data()
    assert metadata['size'] == (494, 286) and abs(metadata['fps'] - SOURCE_FPS) < .001, metadata
    originals = [frame for frame in reader]
    reader.close()
    assert len(originals) == 90, len(originals)
    crop = (32, 88, 88, 144)
    source_masks = []
    for rgb in originals[:56]:
        gray = np.asarray(Image.fromarray(rgb).convert('L'))[crop[1]:crop[3], crop[0]:crop[2]]
        alpha = 255 - gray
        alpha[alpha <= 3] = 0
        source_masks.append(alpha)
    canonical = [normalize(mask, index) for index, mask in enumerate(source_masks)]
    frames = []
    for index in range(55):
        frames.extend([canonical[index].copy(), interpolate(canonical[index], canonical[index + 1], .5)])
    frames.append(canonical[55].copy())
    # Complete the partially observed sixth layer turn, never the whole-image
    # pose. The global clock continues independently through these 13 ticks.
    for step in range(1, 14):
        t = step / 13
        eased = t * t * t * (t * (t * 6 - 15) + 10)
        frames.append(interpolate(canonical[55], canonical[8], eased))
    assert len(frames) == COUNT
    maximum_gutter = 0
    for index, alpha in enumerate(frames):
        alpha[alpha <= 3] = 0
        gutter = np.concatenate((alpha[:2].ravel(), alpha[-2:].ravel(),
                                 alpha[:, :2].ravel(), alpha[:, -2:].ravel()))
        maximum_gutter = max(maximum_gutter, int(gutter.max()))
        assert gutter.max() <= 16, ('Canonical crop clips dots', index, int(gutter.max()))
        alpha[:2] = alpha[-2:] = 0
        alpha[:, :2] = alpha[:, -2:] = 0
    rows = math.ceil(COUNT / COLUMNS)
    atlas = Image.new('RGBA', (COLUMNS * SIDE, rows * SIDE))
    for index, alpha in enumerate(frames):
        rgba = np.zeros((SIDE, SIDE, 4), dtype=np.uint8)
        rgba[:, :, 3] = alpha
        atlas.paste(Image.fromarray(rgba), ((index % COLUMNS) * SIDE, (index // COLUMNS) * SIDE))
    args.output.mkdir(parents=True, exist_ok=True)
    path = args.output / 'thinking-cube-atlas.png'
    atlas.save(path, optimize=True)
    (args.output / 'Contents.json').write_text(json.dumps({
        'images': [{'filename': path.name, 'idiom': 'universal', 'scale': '1x'}],
        'info': {'author': 'xcode', 'version': 1},
        'properties': {'template-rendering-intent': 'template'},
    }, indent=2) + '\n', encoding='utf-8')
    reconstruction = [alpha_error(source, restore(frames[index * 2], index))
                      for index, source in enumerate(source_masks)]
    seam_samples = []
    for repetition in range(8):
        tick = INTRO + (repetition + 1) * LOOP
        seam_samples.append({'tick': tick, 'elapsed': tick / FPS,
                             'continuousGlobalAngleStepDegrees': RATE / 2,
                             'renderedAdjacentAlphaMAE': alpha_error(render_at(frames, (tick - 1) / FPS),
                                                                    render_at(frames, tick / FPS))['meanAbsoluteAlphaByteError']})
    source_bytes = b''.join(mask.tobytes() for mask in source_masks)
    atlas_bytes = COLUMNS * SIDE * rows * SIDE * 4
    total_bytes = atlas_bytes + COUNT * SIDE * SIDE * 4
    assert total_bytes <= MEMORY_BUDGET
    manifest = {
        'schemaVersion': 2, 'sourceSHA256': hashlib.sha256(args.input.read_bytes()).hexdigest(),
        'sourceSize': list(metadata['size']), 'sourceFPS': SOURCE_FPS,
        'sourceTotalFrameCount': len(originals), 'sourceWaitingFramesInclusive': [0, 55],
        'sourceSceneChangeFrame': 56, 'crop': list(crop), 'framesPerSecond': FPS,
        'tileSide': SIDE, 'atlasColumns': COLUMNS, 'atlasRows': rows, 'frameCount': COUNT,
        'introFrameCount': INTRO, 'loopFrameCount': LOOP,
        'sourceLocalLoopFramesInclusive': [8, 55], 'localLoopDuration': LOOP / FPS,
        'sourceCanonicalAtlasIndices': [index * 2 for index in range(56)],
        'sourceFrameAlphaSHA256': [hashlib.sha256(mask.tobytes()).hexdigest() for mask in source_masks],
        'sourceCanonicalAlphaSHA256': [hashlib.sha256(frames[index * 2].tobytes()).hexdigest() for index in range(56)],
        'sourceMasksEncoding': 'zlib+base64; 56 ordered 56x56 uint8 grayscale alpha masks',
        'sourceMasksZlibBase64': base64.b64encode(zlib.compress(source_bytes, 9)).decode('ascii'),
        'globalPose': {'pivotPixels': list(PIVOT), 'sourceFrameOrigin': 8,
                       'openCVAngleDegreesPerSourceFrame': RATE,
                       'swiftRotationSign': -1, 'sourceFramesPerSecond': SOURCE_FPS,
                       'scaleKeyframes': [list(key) for key in SCALE_KEYS],
                       'scaleInterpolation': 'piecewise linear to F52; smoothstep F52..F61; clamp outside',
                       'clock': 'Absolute elapsed time; never the local atlas loop phase',
                       'fitScope': 'Pose estimated from settled F8/17/26/35/43/52; post-F55 pose extrapolated'},
        'normalization': 'warpAffine(source,getRotationMatrix2D(pivot,+angle,scale),INTER_CUBIC|WARP_INVERSE_MAP)',
        'restoration': 'warpAffine(canonical,getRotationMatrix2D(pivot,+angle,scale),INTER_CUBIC); Swift rotates -angle and scales at pivot',
        'reconstructedTail': {'firstAtlasIndex': 111, 'lastAtlasIndex': 123,
                              'sourceFrom': 55, 'canonicalTargetSourceFrame': 8,
                              'duration': 13 / FPS, 'easing': 'smootherstep',
                              'scope': 'Reconstructed final layer completion; source waiting segment has no later frames'},
        'reconstructionMetrics': {
            'units': 'uint8 alpha bytes (0..255); full 56x56 tile',
            'method': 'Original source alpha compared with canonical atlas restored at original global pose',
            'perSourceFrame': reconstruction,
            'meanFrameMAE': float(np.mean([item['meanAbsoluteAlphaByteError'] for item in reconstruction])),
            'maximumFrameMAE': max(item['meanAbsoluteAlphaByteError'] for item in reconstruction),
            'maximumPermittedIndependentBilinearMAE': 1.5},
        'continuityMetrics': {'localLoopEndpointAlphaMAE': alpha_error(frames[-1], frames[INTRO])['meanAbsoluteAlphaByteError'],
                              'localEndpointMeaning': 'Authored endpoint equality verifies closure, not reference fidelity',
                              'globalLoopBoundarySamples': seam_samples},
        'interpolation': 'Offline bidirectional local polynomial optical flow between every observed canonical source frame',
        'atlasSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'decodedAtlasBytes': atlas_bytes, 'decodedAtlasAndFramesBytes': total_bytes,
        'decodedMemoryBudgetBytes': MEMORY_BUDGET, 'maximumPreclearGutterAlpha': maximum_gutter,
        'scope': 'All 56 observed waiting frames retained in canonical coordinates; 60Hz intermediates and final local-layer completion reconstructed. Global pose remains continuous across local loops; later global motion extrapolated.'}
    Path(__file__).with_name('thinking-cube-atlas.json').write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    if args.preview:
        previews(args.preview, source_masks, frames)
        (args.preview / 'authoring-metrics.json').write_text(json.dumps({key: manifest[key] for key in [
            'sourceSHA256', 'atlasSHA256', 'reconstructionMetrics', 'continuityMetrics',
            'globalPose', 'reconstructedTail', 'scope']}, indent=2) + '\n', encoding='utf-8')
    print(json.dumps({key: manifest[key] for key in ['frameCount', 'introFrameCount', 'loopFrameCount',
                                                    'decodedAtlasAndFramesBytes', 'atlasSHA256', 'scope']}, indent=2))


if __name__ == '__main__':
    main()
