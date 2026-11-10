"""Import pinned, attributed vector brand assets. Build/runtime do not fetch icons."""
import concurrent.futures
import hashlib
import json
import re
from pathlib import Path
import urllib.request
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
LOBE = "ea434b96e75813517b377825e01c0df61dee8836"
SIMPLE = "1bb2f6e6ea50f920de8d2f3d273ae48564a5eaee"
ICONS = {
    "OpenAI": "openai", "Anthropic": "anthropic", "Gemini": "gemini-color",
    "Antigravity": "antigravity-color", "OpenRouter": "openrouter",
    "XAI": "xai", "Kimi": "kimi-color", "ElevenLabs": "elevenlabs",
    "Azure": "azure-color", "MiniMax": "minimax-color", "Bailian": "bailian-color",
    "Volcengine": "volcengine-color", "IFlytek": "iflytekcloud-color",
    "MiMo": "xiaomimimo", "DeepSeek": "deepseek-color", "Moonshot": "moonshot",
    "Groq": "groq", "Deepgram": "deepgram",
}


def download(item):
    name, icon = item
    if name == "Deepgram":
        url = f"https://raw.githubusercontent.com/simple-icons/simple-icons/{SIMPLE}/icons/{icon}.svg"
        license_name = "CC0-1.0"
    else:
        url = f"https://raw.githubusercontent.com/lobehub/lobe-icons/{LOBE}/packages/static-svg/icons/{icon}.svg"
        license_name = "MIT"
    mirror = url.replace("https://raw.githubusercontent.com/", "https://cdn.jsdelivr.net/gh/")
    mirror = mirror.replace("/" + LOBE + "/", "@" + LOBE + "/")
    mirror = mirror.replace("/" + SIMPLE + "/", "@" + SIMPLE + "/")
    raw = urllib.request.urlopen(mirror, timeout=25).read()
    ET.fromstring(raw)
    # Apple's SVG compiler expects a concrete fill, with template tint applied by SwiftUI.
    # SVG em units are intended for web fonts; asset catalogs have no font context.
    view_box = ET.fromstring(raw).attrib["viewBox"].split()
    normalized = re.sub(rb'\bwidth="[^"]+"', ('width="' + view_box[2] + '"').encode(), raw, count=1)
    normalized = re.sub(rb'\bheight="[^"]+"', ('height="' + view_box[3] + '"').encode(), normalized, count=1)
    if "width" not in ET.fromstring(normalized).attrib:
        dimensions = ('width="' + view_box[2] + '" height="' + view_box[3] + '" ').encode()
        normalized = normalized.replace(b"<svg ", b"<svg " + dimensions, 1)
    normalized = re.sub(rb'\sstyle="flex:none;line-height:1"', b'', normalized)
    output = normalized.replace(b"currentColor", b"#000000")
    directory = ROOT / "Assets.xcassets" / f"ProviderBrand{name}.imageset"
    directory.mkdir(exist_ok=True)
    (directory / "logo.svg").write_bytes(output)
    color = icon.endswith("-color")
    manifest = {
        "images": [{"filename": "logo.svg", "idiom": "universal"}],
        "info": {"author": "xcode", "version": 1},
        "properties": {"preserves-vector-representation": True,
                       "template-rendering-intent": "original" if color else "template"},
    }
    dark_hash = None
    if name == "Kimi":
        # The source has a currentColor K and a blue dot. Keep the dot while
        # adapting only the monochrome ink to dark appearances.
        dark = normalized.replace(b"currentColor", b"#FFFFFF")
        (directory / "logo-dark.svg").write_bytes(dark)
        manifest["images"].append({"filename": "logo-dark.svg", "idiom": "universal",
                                   "appearances": [{"appearance": "luminosity", "value": "dark"}]})
        dark_hash = hashlib.sha256(dark).hexdigest()
    (directory / "Contents.json").write_text(json.dumps(manifest, indent=2) + "\n")
    return {"asset": directory.name, "source": url, "license": license_name,
            "sourceSHA256": hashlib.sha256(raw).hexdigest(),
            "assetSHA256": hashlib.sha256(output).hexdigest(), "darkAssetSHA256": dark_hash,
            "modification": "Explicit viewBox-sized dimensions; remove web flex style; currentColor to black (white in Kimi dark appearance)"}


if __name__ == "__main__":
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as executor:
        records = list(executor.map(download, ICONS.items()))
    target = ROOT / "docs/provider-brand-assets.json"
    target.write_text(json.dumps(records, indent=2) + "\n")
    for repository, revision, filename, source_name in [
        ("lobehub/lobe-icons", LOBE, "provider-brand-lobe-LICENSE", "LICENSE"),
        ("simple-icons/simple-icons", SIMPLE, "provider-brand-simple-icons-LICENSE", "LICENSE.md"),
    ]:
        url = f"https://cdn.jsdelivr.net/gh/{repository}@{revision}/{source_name}"
        (ROOT / "docs" / filename).write_bytes(urllib.request.urlopen(url, timeout=25).read())
    print(f"Imported {len(records)} pinned vector assets; provenance: {target}")
