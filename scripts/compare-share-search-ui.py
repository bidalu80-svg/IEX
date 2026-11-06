#!/usr/bin/env python3
"""Paired real views. Metrics are diagnostics, never automatic parity claims."""
import json
import pathlib
from PIL import Image, ImageChops, ImageDraw, ImageStat

reference = pathlib.Path("share-search-reference-evidence")
production = pathlib.Path("share-search-production-evidence")
output = pathlib.Path("share-search-comparison-evidence")
output.mkdir(exist_ok=True)
ref = json.loads((reference / "reference-ui-result.json").read_text())
ze = json.loads((production / "production-ui-result.json").read_text())
assert ref["success"] and ze["success"]
assert len(ref["screenshots"]) == len(ze["screenshots"]) == 20
pairs = []
for shot in ref["screenshots"]:
    left = Image.open(reference / shot["file"]).convert("RGB")
    right = Image.open(production / shot["file"].replace("reference-", "production-", 1)).convert("RGB")
    assert left.size == right.size
    width, height = left.size
    pair = Image.new("RGB", (width * 2 + 12, height + 44), "#dedede")
    pair.paste(left, (0, 44)); pair.paste(right, (width + 12, 44))
    draw = ImageDraw.Draw(pair)
    draw.text((12, 12), "REFERENCE 1a71df0f381c", fill="black")
    draw.text((width + 24, 12), "ZE PRODUCTION VIEW", fill="black")
    filename = shot["file"].replace("reference-", "compare-", 1)
    pair.save(output / filename)
    diff = ImageChops.difference(left, right)
    pairs.append({"file": filename, "differenceBounds": diff.getbbox(), "meanAbsoluteChannelDifference": ImageStat.Stat(diff).mean})
(output / "comparison-result.json").write_text(json.dumps({"success": True, "pairs": pairs, "scope": "Same dimensions/scenarios, actual source views. Search bar and share format selector only; caret, spinner, material may vary. Generation success is not visual acceptance."}, indent=2))
print(json.dumps(pairs, indent=2))
