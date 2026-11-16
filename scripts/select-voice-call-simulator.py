#!/usr/bin/env python3
"""Select the requested iOS major, preferring an already booted iPhone."""
import json
import re
import subprocess
import sys

data = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "--json"]))
major = sys.argv[1]
if major == 'auto':
    majors = [int(match.group(1)) for runtime, entries in data['devices'].items()
              if (match := re.search(r'iOS-(\d+)-', runtime))
              and any(device['name'].startswith('iPhone') for device in entries)]
    if not majors:
        raise SystemExit('ERROR: no available iPhone simulator')
    major = str(min(majors))
devices = [device for runtime, entries in data["devices"].items()
           if f"iOS-{major}-" in runtime for device in entries if device["name"].startswith("iPhone")]
if not devices:
    raise SystemExit(f"ERROR: no available iPhone simulator for iOS {major}")
print(next((device["udid"] for device in devices if device["state"] == "Booted"), devices[0]["udid"]))
