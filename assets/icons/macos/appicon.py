#!/usr/bin/env python3
"""Draw the host app icon and emit the macOS asset catalog.

    source-512.png -> master-1024.png -> AppIcon.appiconset/ + NewOldWorld.icns

Since Big Sur a macOS app icon is a rounded square on a 1024 canvas: the body
is 824x824 centred, and the 100px margin is what the system uses for the drop
shadow and hover growth. macOS 26+ masks the icon to that shape itself, so
free-form art either gets clipped or reads as foreign beside every system
icon. The compact Mac therefore sits on a charcoal backdrop, chosen because
it is the only candidate where the beige case still reads at 32px -- on
platinum or cream the case tone matches the backdrop and the machine
dissolves.

The artwork is 512px and there is no vector original, so it is upscaled about
1.5x into the safe area. That is the quality ceiling here; a larger or layered
original would lift it.

Output goes straight into the Xcode target's synchronized folder
(now-host/Sources/Host/Assets.xcassets), so regenerating is the whole update.
"""
from PIL import Image, ImageFilter
from pathlib import Path
import json
import subprocess
import numpy as np

HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
SRC = HERE / "source-512.png"
CATALOG = REPO / "now-host/Sources/Host/Assets.xcassets"
ICONSET = HERE / "NewOldWorld.iconset"

CANVAS, BODY = 1024, 824
SS = 4                                  # supersample factor for the mask
TOP, BOTTOM = (0x4A, 0x4E, 0x57), (0x1E, 0x21, 0x26)


def squircle(size, n=5.0):
    """Continuous-curvature rounded square. A superellipse with n=5 is a close
    stand-in for Apple's corner, and unlike a plain rounded rect it has no
    visible seam where the arc meets the straight edge."""
    s = size * SS
    y, x = np.mgrid[0:s, 0:s]
    c = (s - 1) / 2.0
    d = (np.abs(x - c) / c) ** n + (np.abs(y - c) / c) ** n
    m = np.clip((1.0 - d) * s * 0.25 + 0.5, 0, 1)
    return Image.fromarray((m * 255).astype(np.uint8), "L").resize(
        (size, size), Image.LANCZOS)


def diagonal_gradient(size, top, bottom):
    y, x = np.mgrid[0:size, 0:size]
    t = (x + y) / (2.0 * (size - 1))
    out = np.zeros((size, size, 3), np.uint8)
    for i in range(3):
        out[..., i] = (top[i] + (bottom[i] - top[i]) * t).astype(np.uint8)
    return Image.fromarray(out)


def resize_rgba(img, size, sharpen=False):
    """Downscale with premultiplied alpha.

    Resizing straight RGBA lets the colour of fully transparent pixels bleed
    into the edge, which fringes every boundary -- here a dark halo around the
    tile, since transparent pixels carry black. Premultiply, resize, divide
    back out."""
    a = np.asarray(img).astype(np.float64)
    al = a[..., 3:4] / 255.0
    pm = a.copy()
    pm[..., :3] *= al
    small = Image.fromarray(np.clip(pm, 0, 255).astype(np.uint8), "RGBA") \
        .resize((size, size), Image.LANCZOS)
    b = np.asarray(small).astype(np.float64)
    bl = b[..., 3:4] / 255.0
    b[..., :3] = np.where(bl > 0, b[..., :3] / np.maximum(bl, 1e-6), 0)
    out = Image.fromarray(np.clip(b, 0, 255).astype(np.uint8), "RGBA")
    if sharpen:
        out = out.filter(ImageFilter.UnsharpMask(radius=1.0, percent=70,
                                                 threshold=0))
    return out


def build_master(share=0.76, machine_shadow=True):
    mac = Image.open(SRC).convert("RGBA")
    mask = squircle(BODY)

    body = diagonal_gradient(BODY, np.array(TOP, float), np.array(BOTTOM, float))
    body = body.convert("RGBA")
    body.putalpha(mask)

    canvas = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    off = (CANVAS - BODY) // 2

    shadow = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
    shadow.paste((0, 0, 0, 90), (off, off + 12), mask)
    canvas.alpha_composite(shadow.filter(ImageFilter.GaussianBlur(14)))
    canvas.alpha_composite(body, (off, off))

    # The machine, nudged up: the pedestal is visually heavy, so geometric
    # centring reads as sitting low.
    w = int(BODY * share)
    machine = mac.resize((w, int(mac.height * w / mac.width)), Image.LANCZOS)
    mx = off + (BODY - machine.width) // 2
    my = off + (BODY - machine.height) // 2 - int(BODY * 0.015)

    if machine_shadow:
        cast = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        cast.paste(Image.new("RGBA", machine.size, (0, 0, 0, 110)),
                   (mx, my + 10), machine)
        canvas.alpha_composite(cast.filter(ImageFilter.GaussianBlur(12)))
    canvas.alpha_composite(machine, (mx, my))

    # Clip strays back inside the body, keeping the shadow that falls outside.
    clip = Image.new("L", (CANVAS, CANVAS), 0)
    clip.paste(mask, (off, off))
    a = np.asarray(canvas.getchannel("A"))
    keep = np.minimum(a, np.maximum(np.asarray(clip), a // 4))
    out = canvas.copy()
    out.putalpha(Image.fromarray(keep))
    return out


# macOS wants five logical sizes at 1x and 2x. Ten slots, seven distinct
# pixel sizes -- 32, 128/256 and 512 each serve two slots.
SLOTS = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1),
         (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]


def slot_name(pt, scale):
    return f"icon_{pt}x{pt}{'@2x' if scale == 2 else ''}.png"


# Below 32px the detail loses the argument: the machine's own drop shadow
# becomes a grey smear and the case stops reading against the tile. Apple's
# guidance is to simplify rather than shrink, so the small slots come from a
# second composition -- machine larger in the frame, no cast shadow -- and get
# a light unsharp pass to recover the edges the downscale softens.
SMALL_PX = 32


def main():
    master = build_master()
    small_master = build_master(share=0.88, machine_shadow=False)
    master.save(HERE / "master-1024.png")
    small_master.save(HERE / "master-1024-small.png")

    ICONSET.mkdir(exist_ok=True)
    appicon = CATALOG / "AppIcon.appiconset"
    appicon.mkdir(parents=True, exist_ok=True)

    for pt, scale in SLOTS:
        px = pt * scale
        tiny = px <= SMALL_PX
        img = resize_rgba(small_master if tiny else master, px, sharpen=tiny)
        name = slot_name(pt, scale)
        img.save(ICONSET / name)
        img.save(appicon / name)

    (appicon / "Contents.json").write_text(json.dumps({
        "images": [{"idiom": "mac", "size": f"{pt}x{pt}",
                    "scale": f"{scale}x", "filename": slot_name(pt, scale)}
                   for pt, scale in SLOTS],
        "info": {"version": 1, "author": "xcode"},
    }, indent=2) + "\n")

    (CATALOG / "Contents.json").write_text(json.dumps(
        {"info": {"version": 1, "author": "xcode"}}, indent=2) + "\n")

    # iconutil both produces the .icns and validates the set: it rejects a
    # missing slot or a file whose pixel size disagrees with its name.
    icns = HERE / "NewOldWorld.icns"
    subprocess.run(["iconutil", "-c", "icns", "-o", str(icns), str(ICONSET)],
                   check=True)

    # Review sheet: every rendered size over light and dark, actual pixels.
    # (rendered pixels, the slot it comes from) -- slot names carry the point
    # size, so 64px is 32pt@2x, not "64x64".
    shown = [(16, (16, 1)), (32, (32, 1)), (64, (32, 2)),
             (128, (128, 1)), (256, (256, 1))]
    pad, gap = 24, 22
    widest = max(px for px, _ in shown)
    w = pad * 2 + sum(px for px, _ in shown) + gap * (len(shown) - 1)
    h = pad * 2 + widest
    sheet = Image.new("RGB", (w, h * 2), (0, 0, 0))
    for i, bg in enumerate(((0xEC, 0xEC, 0xEC), (0x2B, 0x2B, 0x2D))):
        band = Image.new("RGB", (w, h), bg)
        x = pad
        for px, (pt, scale) in shown:
            im = Image.open(appicon / slot_name(pt, scale)).convert("RGBA")
            band.paste(im, (x, pad + (widest - px) // 2), im)
            x += px + gap
        sheet.paste(band, (0, i * h))
    sheet.save(HERE / "review.png")
    print(f"master   {HERE / 'master-1024.png'}")
    print(f"catalog  {appicon}  ({len(SLOTS)} slots)")
    print(f"icns     {icns}  ({icns.stat().st_size} bytes)")


if __name__ == "__main__":
    main()
