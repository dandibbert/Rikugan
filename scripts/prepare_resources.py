#!/usr/bin/env python3
"""Generate reproducible demo ZIP and an original, opaque iOS app icon (stdlib only)."""
from pathlib import Path
import json
import math
import struct
import zipfile
import zlib

ROOT = Path(__file__).resolve().parent.parent
resources = ROOT / "Rikugan" / "Resources"
resources.mkdir(parents=True, exist_ok=True)
with zipfile.ZipFile(resources / "DemoExtension.zip", "w", zipfile.ZIP_DEFLATED) as archive:
    for file in sorted((ROOT / "Examples" / "WebExtension").iterdir()):
        info = zipfile.ZipInfo(file.name, date_time=(2026, 1, 1, 0, 0, 0))
        info.compress_type = zipfile.ZIP_DEFLATED
        archive.writestr(info, file.read_bytes())

icon_dir = resources / "Assets.xcassets" / "AppIcon.appiconset"
icon_dir.mkdir(parents=True, exist_ok=True)
(icon_dir.parent / "Contents.json").write_text(json.dumps({"info": {"author": "xcode", "version": 1}}))
(icon_dir / "Contents.json").write_text(json.dumps({"images": [{"filename": "AppIcon.png", "idiom": "universal", "platform": "ios", "size": "1024x1024"}], "info": {"author": "xcode", "version": 1}}))

size = 1024
raw = bytearray()
points = [(512 + 127 * math.cos(i * math.pi / 3), 512 + 127 * math.sin(i * math.pi / 3)) for i in range(6)]
for y in range(size):
    raw.append(0)
    for x in range(size):
        t = (x + y) / (2 * size)
        color = (int(22 + 23*t), int(26 + 64*t), int(76 + 110*t))
        dx, dy = x - 512, y - 512
        eye = (dx/340)**2 + (dy/205)**2
        inner = (dx/315)**2 + (dy/180)**2
        radius = math.hypot(dx, dy)
        if eye < 1 and inner > 1: color = (159, 228, 249)
        if 178 < radius < 192: color = (111, 199, 247)
        if radius < 62: color = (235, 250, 255)
        if any((x-px)**2 + (y-py)**2 < 28**2 for px, py in points): color = (220, 247, 255)
        raw.extend(color)

def chunk(kind, data):
    return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data) & 0xffffffff)
png = b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", size, size, 8, 2, 0, 0, 0)) + chunk(b"IDAT", zlib.compress(bytes(raw), 9)) + chunk(b"IEND", b"")
(icon_dir / "AppIcon.png").write_bytes(png)
print("Generated AppIcon.png and DemoExtension.zip")

