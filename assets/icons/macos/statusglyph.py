#!/usr/bin/env python3
"""Draw the menu-bar status glyphs as macOS template images.

The status item used to be text -- "* New Old World" -- where a single
leading character carried the connection state. A glyph that only replaced
the words would throw that signal away, so the state moved onto the machine's
screen instead: one shape, five fills. The menu bar gets an icon instead of a
sentence, and the state is still readable at a glance.

    notListening  empty screen        was  U+25CB
    waiting       screen with a dot   was  U+25CC
    connected     screen filled       was  U+25CF
    quiet         screen half filled  was  U+25D0
    failed        screen with a bang   was  U+26A0

Template images carry shape in the alpha channel only; macOS paints them
black on a light menu bar, white on a dark one, and inverts them when the
item is held open. So these are drawn as coverage masks -- RGB is zero
everywhere and only alpha varies. Anything with baked-in colour would fight
the system and look wrong in half the states it can be shown in.

macOS displays are 1x or 2x; there is no 3x, so each glyph is 18pt at both.
"""
from PIL import Image, ImageDraw
from pathlib import Path
import json
import re

import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
CATALOG = REPO / "now-host/Sources/Host/Assets.xcassets"

PT = 18                      # menu bar glyphs sit in an 18pt box
SS = 8                       # supersample factor
STATES = ["NotListening", "Waiting", "Connected", "Quiet", "Failed"]

# Geometry in 18pt units. The compact Mac reads from three things at this
# size -- a portrait body, an inset screen and the floppy slot. The pedestal
# is dropped: below about 24pt it is a smudge on the bottom edge.
# Proportions follow the 32x32 drawing: the screen starts about 11% down the
# case and takes just over half its height, leaving a chin of roughly a third.
# A shorter screen makes the body read as a phone rather than a compact Mac.
CASE = (2.6, 1.7, 12.8, 14.6)          # x, y, w, h
SCREEN = (4.4, 3.4, 9.2, 7.6)
SLOT = (8.6, 12.8, 4.2, 0.9)
CASE_STROKE = 1.25
SCREEN_STROKE = 1.0


def draw(state, px):
    s = px * SS
    u = s / PT                          # one point, in supersampled pixels
    img = Image.new("L", (s, s), 0)
    d = ImageDraw.Draw(img)

    def rect(box, inset=0.0):
        x, y, w, h = box
        return [(x + inset) * u, (y + inset) * u,
                (x + w - inset) * u, (y + h - inset) * u]

    # Case: an outline, drawn as a filled round-rect with a smaller one
    # punched out of it.
    d.rounded_rectangle(rect(CASE), radius=2.2 * u, fill=255)
    d.rounded_rectangle(rect(CASE, CASE_STROKE),
                        radius=max(0.4, 2.2 - CASE_STROKE) * u, fill=0)

    # Screen: always outlined; the fill is what says what the wire is doing.
    d.rounded_rectangle(rect(SCREEN), radius=0.9 * u, fill=255)
    d.rounded_rectangle(rect(SCREEN, SCREEN_STROKE), radius=0.4 * u, fill=0)

    sx, sy, sw, sh = SCREEN
    pad = SCREEN_STROKE + 0.55          # keep the fill off the screen frame
    inner = [(sx + pad) * u, (sy + pad) * u,
             (sx + sw - pad) * u, (sy + sh - pad) * u]

    if state == "Connected":
        d.rounded_rectangle(inner, radius=0.3 * u, fill=255)
    elif state == "Quiet":
        # Bottom half only, echoing the half-filled circle it replaces.
        mid = (inner[1] + inner[3]) / 2
        d.rounded_rectangle([inner[0], mid, inner[2], inner[3]],
                            radius=0.3 * u, fill=255)
    elif state == "Waiting":
        cx, cy = (inner[0] + inner[2]) / 2, (inner[1] + inner[3]) / 2
        r = 0.95 * u
        d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=255)
    elif state == "Failed":
        # A bang knocked out of a filled screen: at 18pt an outlined mark
        # inside an outlined screen is two thin lines too many.
        d.rounded_rectangle(inner, radius=0.3 * u, fill=255)
        cx = (inner[0] + inner[2]) / 2
        top, bot = inner[1] + 0.5 * u, inner[3] - 0.4 * u
        w = 0.6 * u
        d.rectangle([cx - w, top, cx + w, bot - 1.5 * u], fill=0)
        d.ellipse([cx - w, bot - 1.2 * u, cx + w, bot], fill=0)
    # NotListening: nothing inside.

    d.rounded_rectangle(rect(SLOT), radius=0.45 * u, fill=255)

    a = img.resize((px, px), Image.LANCZOS)
    out = np.zeros((px, px, 4), np.uint8)
    out[..., 3] = np.asarray(a)         # black, shaped entirely by alpha
    return Image.fromarray(out)


def check_against_swift(emitted):
    """Hold GuestStatus.statusImageName and the emitted assets to agree.

    This cannot be a unit test: the catalog is compiled into the app bundle by
    Xcode, so under `swift test` NSImage(named:) searches the test runner's
    bundle and finds nothing whatever the name says. Here both sides are
    visible at once. A name in the enum with no image degrades the status item
    to text at runtime and nowhere else -- silent exactly where it matters.
    """
    src = REPO / "now-host/Sources/Host/GuestStatus.swift"
    body = src.read_text()
    start = body.find("var statusImageName")
    if start < 0:
        raise SystemExit(f"{src.name}: no statusImageName property to check")
    end = body.find("\n    }", start)
    wanted = set(re.findall(r'"(Status\w+)"', body[start:end]))
    if wanted != emitted:
        raise SystemExit(
            f"GuestStatus.statusImageName and the generator disagree\n"
            f"  only in Swift:     {sorted(wanted - emitted) or '-'}\n"
            f"  only in generator: {sorted(emitted - wanted) or '-'}")
    print(f"  checked: {len(wanted)} names match GuestStatus.statusImageName")


def main():
    for state in STATES:
        name = f"Status{state}"
        d = CATALOG / f"{name}.imageset"
        d.mkdir(parents=True, exist_ok=True)
        images = []
        for scale in (1, 2):
            fn = f"{name}.png" if scale == 1 else f"{name}@2x.png"
            draw(state, PT * scale).save(d / fn)
            images.append({"idiom": "mac", "scale": f"{scale}x",
                           "filename": fn})
        (d / "Contents.json").write_text(json.dumps({
            "images": images,
            "info": {"version": 1, "author": "xcode"},
            "properties": {"template-rendering-intent": "template"},
        }, indent=2) + "\n")
        print(f"  {name}.imageset")
    check_against_swift({f"Status{s}" for s in STATES})

    # Review sheet: template images are alpha-only, so show them the two ways
    # the system will -- black on a light bar, white on a dark one.
    scale, gap, pad = 6, 16, 16
    cell = PT * 2 * scale
    w = pad * 2 + len(STATES) * (cell + gap) - gap
    sheet = Image.new("RGB", (w, (cell + pad * 2) * 2), (0, 0, 0))
    for i, (bg, ink) in enumerate((((0xF2, 0xF2, 0xF2), 0), ((0x2A, 0x2A, 0x2C), 255))):
        band = Image.new("RGB", (w, cell + pad * 2), bg)
        x = pad
        for state in STATES:
            g = draw(state, PT * 2).resize((cell, cell), Image.NEAREST)
            tint = Image.new("RGB", g.size, (ink, ink, ink))
            band.paste(tint, (x, pad), g)
            x += cell + gap
        sheet.paste(band, (0, i * (cell + pad * 2)))
    sheet.save(HERE / "status-glyphs.png")
    print(f"  review: {HERE / 'status-glyphs.png'}  order: {', '.join(STATES)}")


if __name__ == "__main__":
    main()
