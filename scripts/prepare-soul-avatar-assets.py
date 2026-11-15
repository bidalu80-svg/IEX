"""Import user-provided avatar assets unchanged. No matting or re-encoding.
Usage: python scripts/prepare-soul-avatar-assets.py <updated-complete-pack.zip>
"""
from pathlib import Path
import hashlib, json, sys, zipfile
from PIL import Image
import io
ROOT = Path(__file__).resolve().parents[1]

def main():
    archive = Path(sys.argv[1])
    report = {"archive_sha256": hashlib.sha256(archive.read_bytes()).hexdigest(), "assets": {}}
    with zipfile.ZipFile(archive) as z:
        for theme, directory in [("light", "animations"), ("dark", "animations-dark")]:
            for name, clip in [("idle", "idle-and-connecting"), ("working", "working-and-waiting"),
                               ("making", "making-something"), ("celebrate", "milestone-celebrate")]:
                data = z.read(f"muse-avatar-pack/{directory}/{clip}.mp4")
                target = ROOT / f"Assets.xcassets/SoulAvatar-{name}-{theme}.dataset"
                target.mkdir(exist_ok=True)
                (target / "animation.mp4").write_bytes(data)
                (target / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"},
                    "data": [{"filename": "animation.mp4", "idiom": "universal"}]}, indent=2))
                report["assets"][f"{name}-{theme}"] = {"source_sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
        data = z.read("muse-avatar-pack/avatar-main-transparent.png")
        image = Image.open(io.BytesIO(data))
        assert image.mode == "RGBA" and image.width >= 1024 and image.getpixel((0, 0))[3] == 0
        target = ROOT / "Assets.xcassets/SoulAvatar-main.imageset"
        target.mkdir(exist_ok=True)
        (target / "avatar.png").write_bytes(data)
        (target / "Contents.json").write_text(json.dumps({"info": {"version": 1, "author": "xcode"},
            "images": [{"filename": "avatar.png", "idiom": "universal"}]}, indent=2))
        report["assets"]["main"] = {"source_sha256": hashlib.sha256(data).hexdigest(), "bytes": len(data)}
    (ROOT / "scripts/soul-avatar-assets.json").write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))

if __name__ == "__main__": main()
