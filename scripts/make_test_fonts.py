"""Generates the tiny fonts used by the font / icon-font regression tests.

- TestIcons.ttf      : icon font; U+E001 (PUA) has a 3 em wide glyph.
- RikuganTestSans.ttf: "imported" font; 'x' has a 2 em advance so usage is measurable.
- RikuganTestPair.ttc: collection of RikuganTestPairA / RikuganTestPairB (TTC import test).
Run: python3 scripts/make_test_fonts.py  (requires fonttools)
"""
import os
from fontTools.fontBuilder import FontBuilder
from fontTools.pens.ttGlyphPen import TTGlyphPen
from fontTools.ttLib import TTCollection, TTFont

OUT = os.path.join(os.path.dirname(__file__), "..", "Sources", "Rikugan", "Resources", "SelfTest", "fonts")

def box(width):
    pen = TTGlyphPen(None)
    pen.moveTo((50, 0)); pen.lineTo((50, 700)); pen.lineTo((width - 50, 700)); pen.lineTo((width - 50, 0)); pen.closePath()
    return pen.glyph()

def empty():
    return TTGlyphPen(None).glyph()

def build(family, glyphs, path):
    # glyphs: {glyphName: (codepoint or None, advance)}
    order = [".notdef"] + [g for g in glyphs if g != ".notdef"]
    fb = FontBuilder(1000, isTTF=True)
    fb.setupGlyphOrder(order)
    fb.setupCharacterMap({cp: name for name, (cp, _) in glyphs.items() if cp is not None})
    fb.setupGlyf({name: (box(adv) if name != "space" else empty()) for name, (cp, adv) in [(".notdef", (None, 500))] + list(glyphs.items())})
    fb.setupHorizontalMetrics({name: (adv, 0) for name, (cp, adv) in [(".notdef", (None, 500))] + list(glyphs.items())})
    fb.setupHorizontalHeader(ascent=800, descent=-200)
    fb.setupNameTable({"familyName": family, "styleName": "Regular"})
    fb.setupOS2(sTypoAscender=800, usWinAscent=800, usWinDescent=200)
    fb.setupPost()
    fb.save(path)

os.makedirs(OUT, exist_ok=True)
build("TestIcons", {"uniE001": (0xE001, 3000), "space": (0x20, 250)}, os.path.join(OUT, "TestIcons.ttf"))
latin = {chr(c): (c, 2000 if chr(c) == "x" else 600) for c in range(0x61, 0x7B)}
latin["space"] = (0x20, 250)
build("RikuganTestSans", latin, os.path.join(OUT, "RikuganTestSans.ttf"))
build("RikuganTestPairA", latin, "/tmp/pairA.ttf")
build("RikuganTestPairB", latin, "/tmp/pairB.ttf")
collection = TTCollection()
collection.fonts = [TTFont("/tmp/pairA.ttf"), TTFont("/tmp/pairB.ttf")]
collection.save(os.path.join(OUT, "RikuganTestPair.ttc"))
print("fonts written to", os.path.abspath(OUT))
