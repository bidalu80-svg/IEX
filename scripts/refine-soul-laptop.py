"""Refine only the laptop clip's exterior; retain supplied character pixels.
Run after prepare-soul-avatar-assets.py. Requires cv2, numpy, imageio-ffmpeg.
"""
from pathlib import Path
import hashlib, json, subprocess, zipfile, tempfile, sys
import cv2
import numpy as np
import imageio_ffmpeg

root = Path(__file__).resolve().parents[1]
with zipfile.ZipFile(sys.argv[1]) as z, tempfile.TemporaryDirectory() as tmp:
    source = z.read('muse-avatar-pack/animations/working-and-waiting.mp4')
    path = Path(tmp) / 'source.mp4'; path.write_bytes(source)
    cap = cv2.VideoCapture(str(path))
    frames = []
    while True:
        ok, bgr = cap.read()
        if not ok: break
        rgb = cv2.cvtColor(bgr, cv2.COLOR_BGR2RGB)
        low, high = rgb.min(2), rgb.max(2)
        edge = cv2.Canny(rgb, 12, 35)
        barrier = cv2.morphologyEx(cv2.dilate(edge, np.ones((3, 3), np.uint8)),
                                 cv2.MORPH_CLOSE, np.ones((7, 7), np.uint8))
        free = ((low > 185) & ((high - low) < 26) & (barrier == 0)).astype('uint8')
        _, labels = cv2.connectedComponents(free)
        border = np.unique(np.r_[labels[0], labels[-1], labels[:, 0], labels[:, -1]])
        alpha = (~np.isin(labels, border[border != 0])).astype('uint8') * 255
        color = ((high.astype('int16') - low > 28) & (low < 220)).astype('uint8')
        color = cv2.dilate(color, np.ones((1, 13), np.uint8))
        ys = np.arange(rgb.shape[0])[:, None]
        bottom = np.max(np.where(color > 0, ys, -100), axis=0)
        alpha[ys > bottom[None, :] + 3] = 0
        alpha = cv2.morphologyEx(alpha, cv2.MORPH_OPEN,
                               cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7)))
        alpha = cv2.GaussianBlur(alpha, (5, 5), 1)
        frames.append((rgb, alpha))
    cap.release()
    assert len(frames) == 120
    y, x = np.mgrid[:720, :720]
    radial = np.clip(np.sqrt(((x-360)/360)**2 + ((y-360)/360)**2), 0, 1)[..., None]
    dark = np.array([38, 32, 58]) * (1-radial) + np.array([13, 11, 20]) * radial
    report = {'source_sha256': hashlib.sha256(source).hexdigest(), 'frames': len(frames), 'fps': 24, 'outputs': {}}
    for theme in ['light', 'dark']:
        out = root / f'Assets.xcassets/SoulAvatar-working-{theme}.dataset/animation.mp4'
        proc = subprocess.Popen([imageio_ffmpeg.get_ffmpeg_exe(), '-y', '-loglevel', 'error',
            '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '360x360', '-r', '24', '-i', '-',
            '-an', '-c:v', 'libx264', '-crf', '16', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(out)], stdin=subprocess.PIPE)
        for rgb, alpha in frames:
            a = alpha[..., None] / 255
            composite = (rgb*a + (dark if theme == 'dark' else 255)*(1-a)).clip(0,255).astype('uint8')
            proc.stdin.write(cv2.resize(composite, (360,360), interpolation=cv2.INTER_AREA).tobytes())
        proc.stdin.close(); assert proc.wait() == 0
        report['outputs'][theme] = hashlib.sha256(out.read_bytes()).hexdigest()
    (root / 'scripts/soul-laptop-refinement.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
