"""Clean only the dark laptop clip. Light clips always remain archive originals.
Requires cv2, numpy and imageio-ffmpeg. Character colors come from the original video.
"""
from pathlib import Path
import hashlib, json, subprocess, zipfile, tempfile, sys
import cv2
import numpy as np
import imageio_ffmpeg

root = Path(__file__).resolve().parents[1]
cv2.setNumThreads(2)
with zipfile.ZipFile(sys.argv[1]) as z, tempfile.TemporaryDirectory() as tmp:
    source = z.read('muse-avatar-pack/animations/working-and-waiting.mp4')
    # Explicitly restore the light laptop, including after an older script run.
    (root / 'Assets.xcassets/SoulAvatar-working-light.dataset/animation.mp4').write_bytes(source)
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
        rough = (~np.isin(labels, border[border != 0])).astype('uint8') * 255
        ys = np.arange(rgb.shape[0])[:, None]
        chroma = high.astype('int16') - low
        color = cv2.dilate(((chroma > 28) & (low < 220)).astype('uint8'), np.ones((1, 13), np.uint8))
        bottom = np.max(np.where(color > 0, ys, -100), axis=0)
        rough[ys > bottom[None, :] + 3] = 0
        # Refine just the uncertain contour band, protecting the white clothes
        # and computer inside the silhouette as definite foreground.
        mask = np.where(rough > 0, cv2.GC_PR_FGD, cv2.GC_PR_BGD).astype('uint8')
        mask[cv2.erode(rough, np.ones((17, 17), np.uint8)) > 0] = cv2.GC_FGD
        mask[cv2.dilate(rough, np.ones((13, 13), np.uint8)) == 0] = cv2.GC_BGD
        cv2.setRNGSeed(0)
        cv2.grabCut(bgr, mask, None, np.zeros((1, 65), np.float64),
                    np.zeros((1, 65), np.float64), 4, cv2.GC_INIT_WITH_MASK)
        alpha = ((mask == cv2.GC_FGD) | (mask == cv2.GC_PR_FGD)).astype('uint8') * 255
        # Remove only the pale table strip below the laptop's blue base. Do not
        # run a stronger color cutoff through the white hood/body.
        base = cv2.dilate(((chroma > 40) & (low < 200)).astype('uint8'), np.ones((1, 11), np.uint8))
        base_y = np.max(np.where(base > 0, ys, -100), axis=0)
        alpha[(ys > base_y[None, :] + 2) & (base_y[None, :] > rgb.shape[0] * .7)] = 0
        frames.append((rgb, alpha))
    cap.release()
    assert len(frames) == 120
    masks = [a for _, a in frames]
    y, x = np.mgrid[:720, :720]
    radial = np.clip(np.sqrt(((x-360)/360)**2 + ((y-360)/360)**2), 0, 1)[..., None]
    dark = np.array([38, 32, 58]) * (1-radial) + np.array([13, 11, 20]) * radial
    out = root / 'Assets.xcassets/SoulAvatar-working-dark.dataset/animation.mp4'
    proc = subprocess.Popen([imageio_ffmpeg.get_ffmpeg_exe(), '-y', '-loglevel', 'error',
        '-f', 'rawvideo', '-pix_fmt', 'rgb24', '-s', '720x720', '-r', '24', '-i', '-',
        '-an', '-c:v', 'libx264', '-crf', '14', '-pix_fmt', 'yuv420p', '-movflags', '+faststart', str(out)], stdin=subprocess.PIPE)
    for i, (rgb, _) in enumerate(frames):
        mask = np.median(np.stack(masks[max(0, i-1):min(len(masks), i+2)]), axis=0).astype('uint8')
        kernel = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (7, 7))
        mask = cv2.morphologyEx(cv2.morphologyEx(mask, cv2.MORPH_CLOSE, kernel), cv2.MORPH_OPEN, kernel)
        mask = mask.astype('float32') / 255
        smooth = cv2.GaussianBlur(mask, (0, 0), 2.5)
        a = np.clip((smooth - .4) / .5, 0, 1)[..., None]
        composite = (rgb*a + dark*(1-a)).clip(0,255).astype('uint8')
        proc.stdin.write(composite.tobytes())
    proc.stdin.close(); assert proc.wait() == 0
    report = {'source_sha256': hashlib.sha256(source).hexdigest(), 'frames': 120, 'fps': 24,
        'resolution': [720, 720], 'scope': 'dark laptop only; light theme unchanged',
        'edge_cleanup': 'local GrabCut band, table strip removal, temporal median and soft inward contour',
        'outputs': {'dark': hashlib.sha256(out.read_bytes()).hexdigest()}}
    (root / 'scripts/soul-laptop-refinement.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
