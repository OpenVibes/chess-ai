#!/usr/bin/env python3
"""Writes AppIcon.iconset/ for the Chess app: a brown rounded square with a white knight."""
import os
import sys

try:
    from PIL import Image, ImageDraw, ImageFont
except ImportError:
    sys.exit("make-icon.py: Pillow is not installed (pip3 install pillow)")

FONTS = [
    "/System/Library/Fonts/Apple Symbols.ttf",
    "/System/Library/Fonts/Supplemental/Arial Unicode.ttf",
]
GLYPH = "♞"
BASE = 1024
MARGIN = round(BASE * 0.10)
RADIUS = round((BASE - 2 * MARGIN) * 0.22)
GLYPH_SIZE = round(BASE * 0.62)


def load_font():
    for path in FONTS:
        try:
            return ImageFont.truetype(path, GLYPH_SIZE)
        except OSError:
            continue
    sys.exit("make-icon.py: no font with the knight glyph found (tried: %s)" % ", ".join(FONTS))


def render():
    img = Image.new("RGBA", (BASE, BASE), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([MARGIN, MARGIN, BASE - MARGIN - 1, BASE - MARGIN - 1],
                        radius=RADIUS, fill="#A9794F")
    font = load_font()
    l, t, r, b = font.getbbox(GLYPH)
    x = (BASE - (r - l)) / 2 - l
    y = (BASE - (b - t)) / 2 - t
    d.text((x, y), GLYPH, font=font, fill="#FBF7EF")
    return img


def main():
    master = render()
    out = "AppIcon.iconset"
    os.makedirs(out, exist_ok=True)
    for size in (16, 32, 128, 256, 512):
        for scale in (1, 2):
            px = size * scale
            name = "icon_%dx%d%s.png" % (size, size, "@2x" if scale == 2 else "")
            master.resize((px, px), Image.LANCZOS).save(os.path.join(out, name))


if __name__ == "__main__":
    main()
