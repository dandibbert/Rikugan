#!/usr/bin/env python3
"""Select an available iPhone runtime compatible with the active Xcode SDK."""
import json
import re
import subprocess
import sys

sdk_text = subprocess.check_output(["xcrun", "--sdk", "iphonesimulator", "--show-sdk-version"], text=True).strip()
sdk = tuple(int(piece) for piece in sdk_text.split(".")[:2])
listing = json.loads(subprocess.check_output(["xcrun", "simctl", "list", "devices", "available", "-j"], text=True))
candidates = []
for runtime, devices in listing["devices"].items():
    match = re.search(r"\.iOS-(\d+)-(\d+)(?:-|$)", runtime)
    if not match:
        continue
    version = (int(match[1]), int(match[2]))
    if version[0] != sdk[0] or version > sdk:
        continue
    for device in devices:
        if device.get("isAvailable", True) and device["name"].startswith("iPhone"):
            candidates.append((version, device["name"] == "iPhone 16 Pro", device["name"], runtime, device["udid"]))
if not candidates:
    raise SystemExit(f"No compatible iPhone simulator runtime installed for the active SDK {sdk_text}; refusing to select an unrelated newer runtime.")
version, preferred, name, runtime, udid = max(candidates)
print(f"Selected {name}, {runtime}, SDK {sdk_text}", file=sys.stderr)
print(udid)
