"""Render a string from a Tier-2 glyph sheet + metrics JSON.

This is the consumer-side reference: place each glyph at the pen position using
its `left` side bearing and step the pen by `advance`. Used by the acceptance
check to compare a sheet-rendered line against a live-guest capture.
"""

from __future__ import annotations

import json
import os

from PIL import Image


def render_line(pack_dir: str, label: str, text: str, ink=(0, 0, 0)) -> Image.Image:
    sheet = Image.open(os.path.join(pack_dir, "fonts", f"{label}.png")).convert("RGBA")
    with open(os.path.join(pack_dir, "fonts", f"{label}.json")) as fh:
        m = json.load(fh)
    glyphs = m["glyphs"]
    cell_h = m["frectHeight"]
    pen = 0
    # first pass: total width
    width = 0
    for ch in text:
        g = glyphs.get(ch) or glyphs.get(" ")
        width += g["advance"]
    out = Image.new("RGBA", (width + 2, cell_h + 2), (0, 0, 0, 0))
    for ch in text:
        g = glyphs.get(ch)
        if g is None:
            g = glyphs.get(" ")
            pen += g["advance"]
            continue
        if g["w"] > 0:
            crop = sheet.crop((g["x"], g["y"], g["x"] + g["w"], g["y"] + g["h"]))
            out.alpha_composite(crop, (pen + max(0, g["left"]), 0))
        pen += g["advance"]
    if ink != (0, 0, 0):
        px = out.load()
        for y in range(out.height):
            for x in range(out.width):
                if px[x, y][3]:
                    px[x, y] = (*ink, 255)
    return out


if __name__ == "__main__":
    import sys
    pack = sys.argv[1]
    label = sys.argv[2]
    text = sys.argv[3]
    dest = sys.argv[4] if len(sys.argv) > 4 else "/tmp/line.png"
    img = render_line(pack, label, text)
    bg = Image.new("RGBA", img.size, (255, 255, 255, 255))
    bg.alpha_composite(img)
    bg.convert("RGB").save(dest)
    print(f"{dest}  {img.size}")
