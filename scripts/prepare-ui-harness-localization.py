#!/usr/bin/env python3
"""Package real Simplified Chinese catalog strings for standalone UI harnesses."""
import hashlib
import json
import pathlib
import sys

root = pathlib.Path(__file__).resolve().parents[1]
source = root / "Localizable.xcstrings"
catalog = json.loads(source.read_text(encoding="utf-8"))
translations = {
    key: entry["localizations"]["zh-Hans"]["stringUnit"]["value"]
    for key, entry in catalog["strings"].items()
    if "stringUnit" in entry.get("localizations", {}).get("zh-Hans", {})
}
assert translations, "Production catalog contains no zh-Hans stringUnit translations"
for key in ("Waiting for your answer…", "Answered", "Unconfirmed"):
    assert translations.get(key) and translations[key] != key, f"Missing Chinese status translation: {key}"

def quoted(value):
    # Apple .strings accepts these C escapes; keep Chinese as UTF-8 characters.
    return '"' + value.replace('\\', '\\\\').replace('"', '\\"').replace('\n', '\\n').replace('\r', '\\r').replace('\t', '\\t') + '"'

app = pathlib.Path(sys.argv[1])
target = app / "zh-Hans.lproj" / "Localizable.strings"
target.parent.mkdir(parents=True, exist_ok=True)
target.write_text("\n".join(f"{quoted(key)} = {quoted(value)};" for key, value in sorted(translations.items())) + "\n", encoding="utf-8")
manifest = {
    "language": "zh-Hans",
    "source": "Localizable.xcstrings",
    "sourceSHA256": hashlib.sha256(source.read_bytes()).hexdigest(),
    "stringUnits": len(translations),
    "statusTranslations": {key: translations[key] for key in ("Waiting for your answer…", "Answered", "Unconfirmed")},
    "scope": "Production stringUnit values; catalog variations are not used by these harness scenarios",
}
if len(sys.argv) > 2:
    evidence = pathlib.Path(sys.argv[2])
    evidence.mkdir(parents=True, exist_ok=True)
    (evidence / "localization-sources.json").write_text(json.dumps(manifest, ensure_ascii=False, indent=2), encoding="utf-8")
print(json.dumps(manifest, ensure_ascii=False))
