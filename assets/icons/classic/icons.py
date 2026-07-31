#!/usr/bin/env python3
"""Hand-authored classic Mac icons of the New Old World compact Mac.

These are *drawn*, not downsampled. Geometry is derived from the 512px source
by proportion (case 60-450/512 wide, bezel 107-396, floppy slot y~358, Apple
logo x 104-128 y 385-412, face profile nose tip at x~232 y~175), then redrawn
on the icon grid so every feature lands on whole pixels and the profile is
re-sculpted at a slope the grid can actually express.

One semantic grid per size drives all three depths, so the shapes stay
identical across the family and only the ink changes:

    1-bit  ICN# / ics#   black line art, 50% checker for the screen + base
    4-bit  icl4 / ics4   flat fills from the 16-entry Apple palette
    8-bit  icl8 / ics8   same shapes, banded blues + a gray ramp on the case

There is no 16-bit classic icon resource -- icons go 1/4/8 then straight to
32-bit ARGB (it32) -- so the 16-bit rendering stays at full 512px.
"""
from PIL import Image
from pathlib import Path
import numpy as np

HERE = Path(__file__).resolve().parent
OUT = str(HERE / "png")
REF = HERE / "reference"

# Semantic cell labels shared by every depth.
#   .  transparent      K  outline        F  face detail (eyes, smile)
#   C  case body        h  highlight      c  case shading
#   P  pedestal         p  pedestal shading
#   B  screen (blue)    W  face white
#   g y o r u v         Apple logo stripes, top to bottom
DOT = "."


class Grid:
    def __init__(self, n):
        self.n = n
        self.g = [[DOT] * n for _ in range(n)]

    def px(self, x, y, c):
        if 0 <= x < self.n and 0 <= y < self.n:
            self.g[y][x] = c

    def hline(self, y, x0, x1, c):
        for x in range(x0, x1 + 1):
            self.px(x, y, c)

    def vline(self, x, y0, y1, c):
        for y in range(y0, y1 + 1):
            self.px(x, y, c)

    def fill(self, x0, y0, x1, y1, c):
        for y in range(y0, y1 + 1):
            self.hline(y, x0, x1, c)

    def box(self, x0, y0, x1, y1, c):
        self.hline(y0, x0, x1, c)
        self.hline(y1, x0, x1, c)
        self.vline(x0, y0, y1, c)
        self.vline(x1, y0, y1, c)

    def face(self, x0, y0, x1, starts):
        """Paint the white profile: `starts[i]` is the first white column of
        interior row i, measured from the interior's left edge."""
        for i, s in enumerate(starts):
            self.hline(y0 + i, x0 + s, x1, "W")


# --------------------------------------------------------------- 32x32 (icl)

def build32():
    g = Grid(32)
    # Case x 4..28, y 0..27, top corners nipped.
    g.fill(4, 0, 28, 27, "C")
    g.box(4, 0, 28, 27, "K")
    g.px(4, 0, DOT)
    g.px(28, 0, DOT)
    g.px(4, 1, "K")
    g.px(28, 1, "K")
    g.hline(1, 5, 27, "h")
    g.vline(5, 2, 25, "h")
    g.hline(26, 6, 27, "c")
    g.vline(27, 3, 26, "c")

    # Screen bezel x 7..25 y 3..18; interior x 8..24 y 4..17 (17 wide, 14 tall).
    g.fill(7, 3, 25, 18, "K")
    g.fill(8, 4, 24, 17, "B")

    # Sculpted profile: forehead slopes in, nose tips out at row 6, steps back
    # under the nose, lips push out again, jaw recedes.
    g.face(8, 4, 24, [10, 9, 9, 8, 8, 7, 6, 8, 8, 7, 7, 8, 8, 9])

    # Eyes: 1x2, left on the blue field, right on the white face.
    for ex in (4, 11):
        g.px(8 + ex, 7, "F")
        g.px(8 + ex, 8, "F")

    # Smile: shallow arc, ends high, crossing both fields.
    g.px(8 + 3, 13, "F")
    g.px(8 + 13, 13, "F")
    g.px(8 + 4, 14, "F")
    g.px(8 + 12, 14, "F")
    g.hline(15, 8 + 5, 8 + 11, "F")

    # Floppy slot, lower right.
    g.hline(22, 17, 24, "K")

    # Apple logo, lower left: stem pixel over a 3x2 body, six stripes.
    g.px(7, 23, "g")
    for x, c in zip((6, 7, 8), ("o", "o", "r")):
        g.px(x, 24, c)
    for x, c in zip((6, 7, 8), ("u", "v", "v")):
        g.px(x, 25, c)

    # Pedestal x 5..27, y 28..31, inset from the case.
    g.fill(5, 28, 27, 31, "P")
    g.hline(30, 6, 26, "p")
    g.box(5, 28, 27, 31, "K")
    return g


# --------------------------------------------------------------- 16x16 (ics)

def build16():
    g = Grid(16)
    # The case runs the full width here. At 16px there is only one spare pixel
    # between the case edge and the bezel, and spending it is what keeps the
    # icon reading as a computer rather than a black slab with a face on it.
    g.fill(0, 0, 15, 14, "C")
    g.box(0, 0, 15, 14, "K")

    # Bezel x 2..13 y 2..10; interior x 3..12 y 3..9 (10 wide, 7 tall). The
    # seventh row is bought by cutting the base to one row -- at this size the
    # base only has to suggest a plinth, while the screen carries the icon.
    g.fill(2, 2, 13, 10, "K")
    g.fill(3, 3, 12, 9, "B")
    g.face(3, 3, 12, [6, 6, 5, 4, 5, 5, 6])

    # Eyes on interior row 2, one per field.
    g.px(3 + 2, 5, "F")
    g.px(3 + 7, 5, "F")
    # Smile: ends raised a row above the trough, so it arcs.
    g.px(3 + 2, 7, "F")
    g.px(3 + 8, 7, "F")
    g.hline(8, 3 + 3, 3 + 7, "F")

    # Front panel: floppy slot only. The Apple logo is deliberately dropped at
    # this size -- three pixels cannot spell an apple. A 2x2 color block reads
    # as the Windows flag, a centred stem reads as a "T", and a split bottom
    # reads as legs. Shedding it is what real ics# icons do; the 32px version
    # keeps the rainbow logo, where a stem plus two stripes actually fit.
    g.hline(12, 9, 12, "K")

    # Base: a single inset row.
    g.hline(15, 2, 13, "p")
    return g


# ------------------------------------------------------------------- palettes

PAL4 = {
    "K": (0x00, 0x00, 0x00), "F": (0x00, 0x00, 0x00),
    "C": (0xC0, 0xC0, 0xC0), "h": (0xC0, 0xC0, 0xC0), "c": (0x80, 0x80, 0x80),
    "P": (0x80, 0x80, 0x80), "p": (0x40, 0x40, 0x40),
    "B": (0x02, 0xAB, 0xEA), "W": (0xFF, 0xFF, 0xFF), "a": (0x40, 0x40, 0x40),
    "g": (0x1F, 0xB7, 0x14), "y": (0xFC, 0xF3, 0x05), "o": (0xFF, 0x64, 0x03),
    "r": (0xDD, 0x09, 0x07), "u": (0x47, 0x00, 0xA5), "v": (0x00, 0x00, 0xD3),
}

PAL8 = {
    "K": (0x00, 0x00, 0x00), "F": (0x00, 0x00, 0x00),
    "C": (0xDD, 0xDD, 0xDD), "h": (0xEE, 0xEE, 0xEE), "c": (0xBB, 0xBB, 0xBB),
    "P": (0x88, 0x88, 0x88), "p": (0x55, 0x55, 0x55), "W": (0xFF, 0xFF, 0xFF),
    "a": (0x55, 0x55, 0x55),
    "g": (0x33, 0xCC, 0x00), "y": (0xFF, 0xCC, 0x00), "o": (0xFF, 0x66, 0x00),
    "r": (0xCC, 0x00, 0x00), "u": (0x66, 0x00, 0x99), "v": (0x00, 0x66, 0xCC),
}
# 8-bit affords a banded screen: light at the top, deeper toward the bottom.
BLUE8 = [(0x33, 0x99, 0xFF), (0x00, 0x66, 0xFF), (0x00, 0x33, 0xCC)]


def render_color(g, pal, blue_bands=None, screen=None):
    n = g.n
    img = np.zeros((n, n, 4), np.uint8)
    for y in range(n):
        for x in range(n):
            c = g.g[y][x]
            if c == DOT:
                continue
            if c == "B" and blue_bands:
                y0, y1 = screen
                t = (y - y0) / max(1, y1 - y0 + 1)
                rgb = blue_bands[min(len(blue_bands) - 1, int(t * len(blue_bands)))]
            else:
                rgb = pal[c]
            img[y, x] = (*rgb, 255)
    return Image.fromarray(img)


def render_1bit(g, checker=("B", "P", "p"), black=()):
    """Black line art. The screen (and, at 32px, the base) become a grid-aligned
    50% checker; eyes and smile get a 1px white halo so they stay legible
    against it -- the standard trick, since bare black on 50% vanishes. At 16px
    the base is solid instead: a checker one row tall just reads as dashes."""
    n = g.n
    halo = set()
    for y in range(n):
        for x in range(n):
            if g.g[y][x] != "F":
                continue
            for dx, dy in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                nx, ny = x + dx, y + dy
                if 0 <= nx < n and 0 <= ny < n and g.g[ny][nx] == "B":
                    halo.add((nx, ny))

    img = np.zeros((n, n, 4), np.uint8)
    for y in range(n):
        for x in range(n):
            c = g.g[y][x]
            if c == DOT:
                continue
            if c in "KFagyoruv" or c in black:
                v = 0
            elif (x, y) in halo:
                v = 255
            elif c in checker:
                v = 0 if (x + y) % 2 == 0 else 255
            else:
                v = 255
            img[y, x] = (v, v, v, 255)
    return Image.fromarray(img)


def render_mask(g):
    n = g.n
    img = np.zeros((n, n, 4), np.uint8)
    for y in range(n):
        for x in range(n):
            if g.g[y][x] != DOT:
                img[y, x] = (0, 0, 0, 255)
    return Image.fromarray(img)


def sheet(images, scale, gap=8):
    h = max(i.height for i in images) * scale
    w = sum(i.width * scale + gap for i in images) + gap
    out = Image.new("RGB", (w, h + 2 * gap), (128, 128, 128))
    x = gap
    for i in images:
        big = i.resize((i.width * scale, i.height * scale), Image.NEAREST)
        out.paste(big, (x, gap), big)
        x += big.width + gap
    return out


g32, g16 = build32(), build16()
made = []
for g, tag, scr, chk, blk in ((g32, "32", (4, 17), ("B", "P", "p"), ()),
                              (g16, "16", (3, 9), ("B",), ("P", "p"))):
    variants = [
        (render_1bit(g, chk, blk), f"now-{tag}-1bit.png"),
        (render_color(g, PAL4), f"now-{tag}-4bit.png"),
        (render_color(g, PAL8, BLUE8, scr), f"now-{tag}-8bit.png"),
        (render_mask(g), f"now-{tag}-mask.png"),
    ]
    for img, name in variants:
        img.save(f"{OUT}/{name}")
    made.append([v[0] for v in variants])

sheet(made[0], 10).save(str(REF / "preview-32.png"))
sheet(made[1], 20).save(str(REF / "preview-16.png"))
print(f"wrote 32px + 16px families to {OUT}")
