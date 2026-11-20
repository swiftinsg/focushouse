#!/usr/bin/env python3
"""Turn the pixel-art grids into PNG image sets in the asset catalog.

    python3 tools/sprites.py

Reads Art/houses.json (house sprites from tools/house_art.py) and the tab icons
below, and writes focushouse/Assets.xcassets. Pixels are kept at their real
size (96x64 houses); the app scales them up with interpolation off, so they stay
crisp. Standard library only.
"""
import json, os, struct, zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ASSETS = os.path.join(ROOT, "focushouse", "Assets.xcassets")

# Tab icons, the student's own drawings (one grid cell = one drawn pixel), in one
# colour and tinted by the tab bar (template images).
ICONS = {
    "tab.home": [
        ".KKK..........", "..K...........", "..K.KKKKKK....", "..KKKKKKKKK...", "..KKKKKKKKKK..",
        ".KKKKKKKKKKKK.", "KKKKKKKKKKKKKK", "..K........K..", "..K.K....K.K..", "..K.K....K.K..",
        "..K...KK...K..", "..K..KKKK..K..", "..K..KKKK..K..", "..KKKKKKKKKK..",
    ],
    "tab.schedule": [
        "......KKKKK......", "....KK.....KK....", "...K.........K...", "..K.....K.....K..",
        ".K......K......K.", ".K......K......K.", "K.......K.......K", "K.......K.......K",
        "K.......K.......K", "K......K........K", "K.....K.........K", ".K...K.........K.",
        ".K..K..........K.", "..K...........K..", "...K.........K...", "....KK.....KK....",
        "......KKKKK......",
    ],
    "tab.calendar": [
        "...KK...KK...KK...KK.......", "KKKKKKKKKKKKKKKKKKKKKKK....", "K..KK...KK...KK...KK..K....",
        "K..KK...KK...KK...KK..K....", "K.....................K....", "KKKKKKKKKKKKKKKKKKKKKKK....",
        "KKKKKKKKKKKKKKKKKKKKKKK....", "KKKKKKKKKKKKKKKKKKKKKKK....", "K.....................K....",
        "K.....................K....", "K.KKKKK..KKKKK..KKKKK.K....", "K.....................K....",
        "K.....................K....", "K.KKKKK..KKKKK..KKKKK.K....", "K.....................K..KK",
        "K..............KKKKKKKKKKK.", "K.KKKKK..KKKKK.K.......KK..", "K..............K......KKK..",
        "K..............K.....KK.K..", "K..............K.KK.KK..K..", "K..............K..KKK...K..",
        "KKKKKKKKKKKKKKKK...K....K..", "...............K........K..", "...............K........K..",
        "...............KKKKKKKKKK..",
    ],
    "icon.brick": ["KKKKKKKKK", "KRRRKRRRK", "KKKKKKKKK", "KRKRRRKRK", "KKKKKKKKK"],
}
ICON_PALETTE = {"K": "#0f3750", "R": "#eef3f8"}


def png(rows, palette, scale=1):
    """PNG bytes for a grid of palette characters ('.' = transparent)."""
    def rgba(ch):
        if ch == ".":
            return b"\0\0\0\0"
        h = palette[ch].lstrip("#")
        return bytes(int(h[i:i + 2], 16) for i in (0, 2, 4)) + b"\xff"

    raw = b"".join((b"\0" + b"".join(rgba(c) * scale for c in row)) * scale for row in rows)
    w, h = len(rows[0]) * scale, len(rows) * scale

    def chunk(kind, data):
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    return (b"\x89PNG\r\n\x1a\n" + chunk(b"IHDR", struct.pack(">IIBBBBB", w, h, 8, 6, 0, 0, 0))
            + chunk(b"IDAT", zlib.compress(raw, 9)) + chunk(b"IEND", b""))


def imageset(name, rows, palette, template=False, scales=(1,)):
    """Write <name>.imageset. Tab icons get 2x/3x, scaled to about 26 pt with whole
    pixels per drawn cell, so they stay crisp."""
    folder = os.path.join(ASSETS, name + ".imageset")
    os.makedirs(folder, exist_ok=True)
    images = []
    for s in scales:
        file = f"{name}@{s}x.png"
        with open(os.path.join(folder, file), "wb") as f:
            f.write(png(rows, palette, max(1, round(26 * s / max(len(rows), len(rows[0])))) if template else s))
        images.append({"filename": file, "idiom": "universal", "scale": f"{s}x"})
    props = {"template-rendering-intent": "template"} if template else {}
    with open(os.path.join(folder, "Contents.json"), "w") as f:
        json.dump({"images": images, "info": {"author": "xcode", "version": 1}, "properties": props}, f, indent=2)


def main():
    os.makedirs(ASSETS, exist_ok=True)
    with open(os.path.join(ASSETS, "Contents.json"), "w") as f:
        json.dump({"info": {"author": "xcode", "version": 1}}, f, indent=2)

    # house.<state>.<level> (tools/house_art.py), plus house.<state> = level 4 for code without a level.
    houses = json.load(open(os.path.join(ROOT, "Art", "houses.json")))
    for sprite in houses["sprites"]:
        grid = sprite["grid"]
        assert len(grid) == 64 and all(len(r) == 96 for r in grid), sprite["name"]
        imageset("house." + sprite["name"], grid, houses["palette"])
        if sprite["name"].endswith(".4"):
            imageset("house." + sprite["name"][:-2], grid, houses["palette"])

    for name, grid in ICONS.items():
        template = name.startswith("tab.")
        imageset(name, grid, ICON_PALETTE, template=template, scales=(2, 3) if template else (1,))
    print("wrote", ASSETS)


if __name__ == "__main__":
    main()
