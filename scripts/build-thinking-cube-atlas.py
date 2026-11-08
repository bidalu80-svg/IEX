#!/usr/bin/env python3
"""Build the bounded, transparent thinking glyph from a supplied reference clip.

Offline authoring only: pip install imageio imageio-ffmpeg opencv-python-headless pillow.
The app ships the resulting PNG; no video decoder or optical flow runs on the phone.
"""
import argparse
import hashlib
import json
from pathlib import Path

import cv2
import imageio.v2 as imageio
import numpy as np
from PIL import Image


def interpolate(left, right, fraction):
    """Bidirectional motion interpolation preserves the individual dot trajectories."""
    if fraction == 0:
        return left.copy()
    if fraction == 1:
        return right.copy()
    size = left.shape[0]
    a = cv2.resize(left, (size * 4, size * 4), interpolation=cv2.INTER_CUBIC)
    b = cv2.resize(right, (size * 4, size * 4), interpolation=cv2.INTER_CUBIC)
    flow = cv2.DISOpticalFlow_create(cv2.DISOPTICAL_FLOW_PRESET_MEDIUM)
    ab = flow.calc(a, b, None)
    ba = flow.calc(b, a, None)
    y, x = np.mgrid[:a.shape[0], :a.shape[1]].astype(np.float32)
    first = cv2.remap(a, x - ab[:, :, 0] * fraction, y - ab[:, :, 1] * fraction,
                      cv2.INTER_CUBIC, borderMode=cv2.BORDER_CONSTANT)
    second = cv2.remap(b, x - ba[:, :, 0] * (1 - fraction),
                       y - ba[:, :, 1] * (1 - fraction), cv2.INTER_CUBIC,
                       borderMode=cv2.BORDER_CONSTANT)
    mixed = first.astype(np.float32) * (1 - fraction) + second.astype(np.float32) * fraction
    return cv2.resize(np.uint8(np.clip(mixed, 0, 255)), (size, size), interpolation=cv2.INTER_AREA)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('input', type=Path)
    parser.add_argument('--output', type=Path,
                        default=Path(__file__).resolve().parents[1] / 'Assets.xcassets/ThinkingCubeAtlas.imageset')
    parser.add_argument('--preview', type=Path)
    args = parser.parse_args()
    reader = imageio.get_reader(str(args.input), 'ffmpeg')
    metadata = reader.get_meta_data()
    assert metadata['size'] == (494, 286) and abs(metadata['fps'] - 30) < 0.001, metadata
    original = [frame for frame in reader]
    reader.close()
    # This square excludes the label; every edge is transparent in all retained frames.
    crop = (32, 88, 88, 144)
    masks = []
    for rgb in original[:35]:
        gray = np.asarray(Image.fromarray(rgb).convert('L'))[crop[1]:crop[3], crop[0]:crop[2]]
        mask = 255 - gray
        mask[mask <= 3] = 0  # Remove white-background compression noise only.
        masks.append(mask)
    frames = []
    for index in range(34):
        frames += [masks[index], interpolate(masks[index], masks[index + 1], 0.5)]
    # The three observed layer turns are followed by a short settled join.
    # Smoothstep makes that small camera-pose correction settle at both ends.
    for step in range(6):
        fraction = step / 5
        eased = fraction * fraction * (3 - 2 * fraction)
        frames.append(interpolate(masks[34], masks[6], eased))
    assert len(frames) == 74
    atlas = Image.new('RGBA', (8 * 56, 10 * 56))
    for index, alpha in enumerate(frames):
        alpha[alpha <= 3] = 0
        border = np.concatenate((alpha[:2].ravel(), alpha[-2:].ravel(),
                                 alpha[:, :2].ravel(), alpha[:, -2:].ravel()))
        assert border.max() <= 8, ('visible content at crop edge', index)
        # The clip has faint codec ringing above the dots. Keep a two-pixel
        # transparent gutter after checking it contains no visible dot content.
        alpha[:2] = alpha[-2:] = 0
        alpha[:, :2] = alpha[:, -2:] = 0
        assert not alpha[:2].any() and not alpha[-2:].any(), ('vertical crop', index)
        assert not alpha[:, :2].any() and not alpha[:, -2:].any(), ('horizontal crop', index)
        rgba = np.zeros((56, 56, 4), dtype=np.uint8)
        rgba[:, :, 3] = alpha
        atlas.paste(Image.fromarray(rgba), ((index % 8) * 56, (index // 8) * 56))
    args.output.mkdir(parents=True, exist_ok=True)
    path = args.output / 'thinking-cube-atlas.png'
    atlas.save(path, optimize=True)
    (args.output / 'Contents.json').write_text(json.dumps({
        'images': [{'filename': path.name, 'idiom': 'universal', 'scale': '1x'}],
        'info': {'author': 'xcode', 'version': 1},
        'properties': {'template-rendering-intent': 'template'},
    }, indent=2) + '\n', encoding='utf-8')
    manifest = {
        'sourceSHA256': hashlib.sha256(args.input.read_bytes()).hexdigest(),
        'sourceSize': list(metadata['size']), 'sourceFPS': 30,
        'crop': list(crop), 'framesPerSecond': 60,
        'tileSide': 56, 'atlasColumns': 8, 'frameCount': 74,
        'introFrameCount': 12, 'loopFrameCount': 62,
        'sourceLoopFramesInclusive': [6, 34], 'joinDuration': 0.1,
        'sourceFrameAlphaSHA256': [hashlib.sha256(mask.tobytes()).hexdigest() for mask in masks],
        'interpolation': 'Offline bidirectional DIS optical flow; smoothstep loop join',
        'atlasSHA256': hashlib.sha256(path.read_bytes()).hexdigest(),
        'decodedAtlasBytes': 448 * 560 * 4,
        'scope': 'Reference-derived raster motion at the supplied resolution. Loop closure and intermediate frames are reconstructed.',
    }
    manifest_path = Path(__file__).with_name('thinking-cube-atlas.json')
    manifest_path.write_text(json.dumps(manifest, indent=2) + '\n', encoding='utf-8')
    if args.preview:
        args.preview.mkdir(parents=True, exist_ok=True)
        loop = []
        for mask in frames[12:]:
            frame = np.full((56, 56, 3), 255, dtype=np.uint8) - mask[:, :, None]
            loop.append(np.asarray(Image.fromarray(frame).resize((336, 336), Image.Resampling.LANCZOS)))
        imageio.mimwrite(str(args.preview / 'cube-motion-preview.mp4'), loop * 3, fps=60, codec='libx264', quality=9)
        Image.fromarray(loop[0]).save(args.preview / 'cube-motion-poster.png')
    print(json.dumps({k: v for k, v in manifest.items() if k != 'sourceFrameAlphaSHA256'}, indent=2))


if __name__ == '__main__':
    main()
