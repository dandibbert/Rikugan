#!/usr/bin/env python3
"""Generates Rikugan's icon set: Phosphor icons (MIT, https://phosphoricons.com) converted to
Xcode custom symbols named "rk.<SF Symbol name>".

The app keeps using SF Symbol names everywhere; `Icons` (Sources/Rikugan/Browser/Icons.swift)
draws the "rk." custom symbol when one exists and the system symbol otherwise. Custom symbols
behave like SF Symbols (scale with the font, take the tint, work in UIKit menus).

Usage:  npm pack @phosphor-icons/core && tar xzf phosphor-icons-core-*.tgz
        python3 scripts/gen_icons.py <path to package/assets>
Requires: pip install svgelements
"""
import json
import os
import re
import shutil
import sys

from svgelements import Matrix, Path, SVG

# SF Symbol name -> (Phosphor name, weight)
MAP = {
    # Profile icons (Settings → 身份)
    "airplane": ("airplane", "regular"),
    "bag": ("handbag", "regular"),
    "bolt": ("lightning", "regular"),
    "building.2": ("buildings", "regular"),
    "camera": ("camera", "regular"),
    "cloud": ("cloud", "regular"),
    "cup.and.saucer": ("coffee", "regular"),
    "dumbbell": ("barbell", "regular"),
    "flame": ("fire", "regular"),
    "gift": ("gift", "regular"),
    "heart": ("heart", "regular"),
    "leaf": ("leaf", "regular"),
    "paintpalette": ("palette", "regular"),
    "pawprint": ("paw-print", "regular"),
    "sparkles": ("sparkle", "regular"),
    "sun.max": ("sun", "regular"),
    "ticket": ("ticket", "regular"),
    "tree": ("tree", "regular"),
    "person.2": ("users", "regular"),
    "figure.child": ("baby", "regular"),
    "banknote": ("money", "regular"),
    "headphones": ("headphones", "regular"),
    "fork.knife": ("fork-knife", "regular"),
    "sailboat": ("sailboat", "regular"),
    "clipboard": ("clipboard-text", "regular"),
    "arrow.clockwise": ("arrow-clockwise", "regular"),
    "arrow.clockwise.circle.fill": ("arrow-clockwise", "bold"),
    "arrow.down.circle": ("arrow-circle-down", "regular"),
    "arrow.left.square": ("arrow-square-left", "regular"),
    "arrow.right.square": ("arrow-square-right", "regular"),
    "arrow.triangle.2.circlepath": ("arrows-clockwise", "regular"),
    "arrow.triangle.branch": ("git-branch", "regular"),
    "arrow.up.arrow.down": ("arrows-down-up", "regular"),
    "arrow.up.arrow.down.square": ("arrows-down-up", "regular"),
    "arrow.up.left.and.arrow.down.right": ("arrows-out", "regular"),
    "arrow.up.right.square": ("arrow-square-out", "regular"),
    "arrow.up.to.line": ("arrow-line-up", "regular"),
    "arrow.uturn.backward": ("arrow-u-up-left", "regular"),
    "bell": ("bell", "regular"),
    "book": ("book-open", "regular"),
    "bookmark": ("bookmark-simple", "regular"),
    "briefcase": ("briefcase", "regular"),
    "cart": ("shopping-cart", "regular"),
    "character.bubble": ("translate", "regular"),
    "checklist": ("list-checks", "regular"),
    "checkmark": ("check", "regular"),
    "checkmark.circle": ("check-circle", "regular"),
    "checkmark.circle.fill": ("check-circle", "fill"),
    "chevron.backward": ("caret-left", "regular"),
    "chevron.down": ("caret-down", "regular"),
    "chevron.forward": ("caret-right", "regular"),
    "chevron.up": ("caret-up", "regular"),
    "circle": ("circle", "regular"),
    "circle.slash": ("prohibit", "regular"),
    "clock": ("clock", "regular"),
    "clock.arrow.circlepath": ("clock-counter-clockwise", "regular"),
    "creditcard": ("credit-card", "regular"),
    "curlybraces": ("brackets-curly", "regular"),
    "curlybraces.square.fill": ("brackets-curly", "bold"),
    "desktopcomputer": ("desktop", "regular"),
    "doc": ("file", "regular"),
    "doc.on.doc": ("copy", "regular"),
    "doc.plaintext": ("article", "regular"),
    "doc.richtext": ("file-pdf", "regular"),
    "doc.text": ("file-text", "regular"),
    "doc.text.magnifyingglass": ("file-magnifying-glass", "regular"),
    "doc.zipper": ("file-zip", "regular"),
    "dot.radiowaves.left.and.right": ("broadcast", "regular"),
    "ellipsis.circle": ("dots-three-circle", "regular"),
    "exclamationmark.circle": ("warning-circle", "regular"),
    "exclamationmark.triangle": ("warning", "regular"),
    "exclamationmark.triangle.fill": ("warning", "fill"),
    "eye": ("eye", "regular"),
    "eye.circle.fill": ("eye", "fill"),
    "eye.slash": ("eye-slash", "regular"),
    "film": ("film-strip", "regular"),
    "flask": ("flask", "regular"),
    "folder": ("folder", "regular"),
    "folder.badge.minus": ("folder-minus", "regular"),
    "gamecontroller": ("game-controller", "regular"),
    "gearshape": ("gear-six", "regular"),
    "globe": ("globe-simple", "regular"),
    "graduationcap": ("graduation-cap", "regular"),
    "hammer": ("hammer", "regular"),
    "hand.raised": ("hand", "regular"),
    "hand.raised.circle.fill": ("hand", "fill"),
    "hand.raised.fill": ("hand", "fill"),
    "house": ("house", "regular"),
    "info.circle": ("info", "regular"),
    "iphone": ("device-mobile", "regular"),
    "key": ("key", "regular"),
    "ladybug": ("bug-beetle", "regular"),
    "link": ("link", "regular"),
    "lock.fill": ("lock", "fill"),
    "lock.open": ("lock-open", "regular"),
    "lock.slash": ("lock-open", "regular"),
    "magnifyingglass": ("magnifying-glass", "regular"),
    "minus.circle": ("minus-circle", "regular"),
    "moon": ("moon", "regular"),
    "music.note": ("music-note", "regular"),
    "paintbrush": ("paint-brush", "regular"),
    "pause": ("pause", "regular"),
    "pause.circle.fill": ("pause-circle", "fill"),
    "pencil": ("pencil-simple", "regular"),
    "person.crop.circle": ("user-circle", "regular"),
    "person.text.rectangle": ("identification-card", "regular"),
    "photo": ("image", "regular"),
    "photo.on.rectangle": ("images", "regular"),
    "pin": ("push-pin", "regular"),
    "pin.fill": ("push-pin", "fill"),
    "pip.enter": ("picture-in-picture", "regular"),
    "play.circle": ("play-circle", "regular"),
    "play.rectangle": ("monitor-play", "regular"),
    "play.rectangle.on.rectangle": ("film-slate", "regular"),
    "playpause": ("play-pause", "regular"),
    "plus": ("plus", "regular"),
    "plus.square.on.square": ("plus-square", "regular"),
    "printer": ("printer", "regular"),
    "puzzlepiece.extension": ("puzzle-piece", "regular"),
    "puzzlepiece.extension.fill": ("puzzle-piece", "fill"),
    "qrcode": ("qr-code", "regular"),
    "qrcode.viewfinder": ("scan", "regular"),
    "questionmark.circle": ("question", "regular"),
    "rectangle.and.pencil.and.ellipsis": ("textbox", "regular"),
    "safari": ("compass", "regular"),
    "shield": ("shield", "regular"),
    "shield.lefthalf.filled": ("shield-check", "regular"),
    "shield.slash": ("shield-slash", "regular"),
    "sidebar.left": ("sidebar-simple", "regular"),
    "slider.horizontal.3": ("sliders-horizontal", "regular"),
    "square.and.arrow.down": ("download-simple", "regular"),
    "square.and.arrow.up": ("export", "regular"),
    "square.grid.2x2": ("squares-four", "regular"),
    "square.on.square": ("cards", "regular"),
    "square.on.square.dashed": ("selection-plus", "regular"),
    "star": ("star", "regular"),
    "star.fill": ("star", "fill"),
    "stethoscope": ("stethoscope", "regular"),
    "textformat": ("text-aa", "regular"),
    "textformat.size": ("text-aa", "regular"),
    "textformat.size.larger": ("magnifying-glass-plus", "regular"),
    "textformat.size.smaller": ("magnifying-glass-minus", "regular"),
    "timer": ("timer", "regular"),
    "trash": ("trash", "regular"),
    "video": ("video-camera", "regular"),
    "video.slash": ("video-camera-slash", "regular"),
    "waveform.path.ecg": ("heartbeat", "regular"),
    "wifi.exclamationmark": ("wifi-x", "regular"),
    "wrench.and.screwdriver": ("wrench", "regular"),
    "xmark": ("x", "regular"),
    "xmark.circle": ("x-circle", "regular"),
    "xmark.circle.fill": ("x-circle", "fill"),
    "xmark.octagon.fill": ("x-circle", "fill"),
    "xmark.square": ("x-square", "regular"),
}

# Xcode custom-symbol template (v3) geometry for the Regular-M glyph. Like Apple's templates, the
# glyph is drawn in local coordinates (origin = left margin on the baseline, y up is negative)
# inside a <g id="Regular-M"> that is translated to its place on the artboard.
BASELINE_M = 1126.0
CAPLINE_M = 1055.54
CAP_HEIGHT = BASELINE_M - CAPLINE_M
UNIT = 100.0 / 256.0          # a 256-unit Phosphor box becomes 100 template units
PAD = 16                      # Phosphor units kept as side bearing on each side
GLYPH_X = 1391.0              # artboard x of the Regular-M left margin


def glyph_path(svg_file):
    svg = SVG.parse(svg_file)
    out = []
    for element in svg.elements():
        if isinstance(element, Path):
            path = Path(element)
            # Local coordinates: x from the left margin, the 256 box centred on the cap-height midline.
            path *= Matrix(f"translate({-PAD * UNIT}, {-CAP_HEIGHT / 2 - 128 * UNIT}) scale({UNIT})")
            path.reify()
            out.append(path.d())
    if not out:
        raise SystemExit(f"no path in {svg_file}")
    return " ".join(out)


def template(d):
    left = GLYPH_X
    right = GLYPH_X + (256 - 2 * PAD) * UNIT
    guide = 'style="fill:none;stroke:#27AAE1;opacity:1;stroke-width:0.5;"'
    lines = []
    for size, base, cap in (("S", 696.0, 625.541), ("M", BASELINE_M, CAPLINE_M), ("L", 1556.0, 1485.54)):
        lines.append(f'<line id="Baseline-{size}" {guide} x1="263" x2="3036" y1="{base}" y2="{base}"/>')
        lines.append(f'<line id="Capline-{size}" {guide} x1="263" x2="3036" y1="{cap}" y2="{cap}"/>')
    margin = 'style="fill:none;stroke:#00AEEF;stroke-width:0.5;opacity:1.0;"'
    lines.append(f'<line id="left-margin-Regular-M" {margin} x1="{left:.3f}" x2="{left:.3f}" y1="1030.79" y2="1150.12"/>')
    lines.append(f'<line id="right-margin-Regular-M" {margin} x1="{right:.3f}" x2="{right:.3f}" y1="1030.79" y2="1150.12"/>')
    return f'''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE svg PUBLIC "-//W3C//DTD SVG 1.1//EN" "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd">
<svg version="1.1" xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" width="3300" height="2200">
<!--Phosphor Icons (MIT) converted for Rikugan by scripts/gen_icons.py-->
<g id="Notes">
<rect height="2200" id="artboard" style="fill:white;opacity:1" width="3300" x="0" y="0"/>
<text id="template-version" style="stroke:none;fill:black;font-family:sans-serif;font-size:13;" transform="matrix(1 0 0 1 3036 1933)">Template v.3.0</text>
</g>
<g id="Guides">
{chr(10).join(lines)}
</g>
<g id="Symbols">
<g id="Regular-M" transform="matrix(1 0 0 1 {GLYPH_X} {BASELINE_M})">
<path d="{d}"/>
</g>
</g>
</svg>
'''


def main():
    assets = sys.argv[1] if len(sys.argv) > 1 else "package/assets"
    root = os.path.join(os.path.dirname(__file__), "..", "Sources/Rikugan/Resources/Assets.xcassets/Icons")
    if os.path.isdir(root):
        shutil.rmtree(root)
    os.makedirs(root)
    with open(os.path.join(root, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)
    names = []
    for sf, (ph, weight) in sorted(MAP.items()):
        suffix = "" if weight == "regular" else "-" + weight
        source = os.path.join(assets, weight, f"{ph}{suffix}.svg")
        if not os.path.exists(source):
            raise SystemExit(f"missing Phosphor icon {weight}/{ph} for {sf}")
        name = "rk." + sf
        folder = os.path.join(root, name + ".symbolset")
        os.makedirs(folder)
        with open(os.path.join(folder, name + ".svg"), "w") as f:
            f.write(template(glyph_path(source)))
        with open(os.path.join(folder, "Contents.json"), "w") as f:
            json.dump({"info": {"author": "xcode", "version": 1},
                       "symbols": [{"filename": name + ".svg", "idiom": "universal"}]}, f, indent=2)
        names.append(sf)
    # The list the app checks at runtime / in tests.
    listing = os.path.join(os.path.dirname(__file__), "..", "Sources/Rikugan/Resources/JS/icon-names.json")
    with open(listing, "w") as f:
        json.dump(sorted(names), f, indent=0)
    print(f"{len(names)} icons written to {os.path.normpath(root)}")


if __name__ == "__main__":
    main()
