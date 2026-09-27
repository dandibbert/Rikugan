"""Cheap preflight validation before consuming a macOS build runner."""
from pathlib import Path
import plistlib
import json

ROOT = Path(__file__).resolve().parents[1]
checked = 0
for directory in ("Rikugan", "ShareExtension"):
    for file in (ROOT / directory).rglob("*"):
        if file.suffix in (".plist", ".entitlements"):
            with file.open("rb") as stream:
                plistlib.load(stream)
            checked += 1
for file in (ROOT / "Examples").rglob("manifest.json"):
    manifest = json.loads(file.read_text())
    assert manifest.get("manifest_version") == 3, file
for directory in ("Rikugan", "ShareExtension", "Tests", "UITests", ".github", "scripts"):
    for file in (ROOT / directory).rglob("*"):
        if file.suffix not in (".swift", ".js", ".cjs", ".yml"):
            continue
        for line in file.read_text().splitlines():
            assert not line.startswith(("<" * 7, ">" * 7)), f"Unresolved merge conflict: {file}"
print(f"PASS: {checked} property lists, extension manifests and merge integrity")
