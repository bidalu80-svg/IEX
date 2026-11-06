#!/usr/bin/env python3
"""Create reviewable reference/Ze pairs; metrics do not claim visual parity."""
import json
import pathlib
from PIL import Image, ImageDraw, ImageChops, ImageStat

reference = pathlib.Path("subagent-reference-evidence")
local = pathlib.Path("subagent-ui-evidence")
output = pathlib.Path("subagent-comparison-evidence")
output.mkdir(exist_ok=True)
upstream = json.loads((reference / "upstream-sources.json").read_text())
reference_result = json.loads((reference / "reference-ui-result.json").read_text())
local_result = json.loads((local / "subagent-ui-result.json").read_text())
assert reference_result["success"] and local_result["success"], "Both real renderers must succeed"
pairs = []
for shot in reference_result["screenshots"]:
    ref_file = reference / shot["file"]
    ze_file = local / shot["file"].replace("reference-", "subagent-", 1)
    left = Image.open(ref_file).convert("RGB")
    right = Image.open(ze_file).convert("RGB")
    assert left.size == right.size, (ref_file, left.size, ze_file, right.size)
    width, height = left.size
    pair = Image.new("RGB", (width * 2 + 12, height + 44), "#dedede")
    pair.paste(left, (0, 44)); pair.paste(right, (width + 12, 44))
    draw = ImageDraw.Draw(pair)
    draw.text((12, 12), "REFERENCE " + upstream["commit"][:12], fill="black")
    draw.text((width + 24, 12), "ZE - CURRENT WORKTREE", fill="black")
    name = shot["file"].replace("reference-", "compare-", 1)
    pair.save(output / name)
    # Countdown ticks, system keyboard and antialiasing may differ. Keep this
    # diagnostic numeric value out of pass/fail and require human image review.
    diff = ImageChops.difference(left, right)
    pairs.append({"file": name, "reference": str(ref_file), "ze": str(ze_file),
                  "size": list(left.size), "meanAbsoluteChannelDifference": ImageStat.Stat(diff).mean})
result = {"success": True, "referenceCommit": upstream["commit"], "pairs": pairs,
          "meaning": "Original upstream inline and raw thumbnail plus original digest detail sections versus Ze production cards at identical dimensions and task inputs. Upstream parent floating bar rim and complete detail sheet are outside this capture. Pair generation is not visual acceptance or device FPS evidence."}
(output / "comparison-result.json").write_text(json.dumps(result, indent=2), encoding="utf-8")
print(json.dumps(result, indent=2))
