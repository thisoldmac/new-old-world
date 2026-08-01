#!/usr/bin/env python3
"""Platinum asset extractor: pull -> parse -> render -> manifest.

Produces assets/platinum-pack/ from a live OS 9.1 guest (or a
local cache of pulled resource forks). Everything is read-only against the guest.

    # end to end against a fresh VM (anchor worker on host port 1405 -> guest :1400)
    python3 extract.py --port 1405

    # re-render from an existing cache without touching the guest
    python3 extract.py --cache .cache

The pack is Apple's copyrighted bitmap/font data; it stays in this private repo
(see ASSET-EXTRACTION.md "Rules"). Do not publish it.
"""

from __future__ import annotations

import argparse
import ctypes
import datetime
import json
import os

import clut
import cursors
import fonts
import icons
import patterns
import pull
import resfork

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.abspath(os.path.join(HERE, "..", ".."))   # this repo
LAB = os.path.abspath(os.path.join(MIRROR, ".."))          # lab checkout (harness)

STYLE_SUFFIX = {0: "", 1: "-bold", 2: "-italic", 3: "-bolditalic"}

# face name -> (suitcase file, FOND id). FOND id is informational/provenance.
FACES = {
    "Chicago":  "Chicago.rsrc",
    "Charcoal": "Charcoal.rsrc",
    "Geneva":   "Geneva.rsrc",
}


def _validate_ttf(path: str) -> bool:
    """Load the font through CoreText to prove it is a usable system font."""
    try:
        ct = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/CoreText.framework/CoreText")
        cf = ctypes.cdll.LoadLibrary(
            "/System/Library/Frameworks/CoreFoundation.framework/CoreFoundation")
    except OSError:
        return False  # not on macOS; header check already passed upstream
    cf.CFStringCreateWithCString.restype = ctypes.c_void_p
    cf.CFURLCreateFromFileSystemRepresentation.restype = ctypes.c_void_p
    ct.CTFontManagerCreateFontDescriptorsFromURL.restype = ctypes.c_void_p
    p = path.encode()
    url = cf.CFURLCreateFromFileSystemRepresentation(
        None, p, len(p), False)
    if not url:
        return False
    descs = ct.CTFontManagerCreateFontDescriptorsFromURL(ctypes.c_void_p(url))
    ok = bool(descs)
    if descs:
        cf.CFRelease(ctypes.c_void_p(descs))
    cf.CFRelease(ctypes.c_void_p(url))
    return ok


def extract_fonts(cache: dict[str, str], out_dir: str, prov: list) -> dict:
    font_dir = os.path.join(out_dir, "fonts")
    ttf_dir = os.path.join(font_dir, "ttf")
    os.makedirs(ttf_dir, exist_ok=True)
    summary = {"ttf": {}, "sheets": {}, "notes": {}}

    for face, fname in FACES.items():
        fork = resfork.load(cache[fname])
        rel = f"System Folder:Fonts:{face}"

        # Tier 1: sfnt -> ttf
        sres = fork.of_type("sfnt")
        if sres:
            ttf = fonts.sfnt_to_ttf(sres[0].data)
            tp = os.path.join(ttf_dir, f"{face}.ttf")
            with open(tp, "wb") as fh:
                fh.write(ttf)
            valid = _validate_ttf(tp)
            summary["ttf"][face] = {"bytes": len(ttf), "coretext_valid": valid}
            prov.append({"asset": f"fonts/ttf/{face}.ttf", "source": rel,
                         "type": "sfnt", "id": sres[0].id})

        # Tier 2: one sheet per NFNT strike, sized via the FOND assoc table.
        fond = fork.of_type("FOND")
        size_by_id: dict[int, tuple[int, int]] = {}
        if fond:
            _, assoc = fonts.parse_fond(fond[0].data)
            for a in assoc:
                size_by_id[a.font_id] = (a.size, a.style)

        strikes = fork.of_type("NFNT")
        if not strikes:
            summary["notes"][face] = (
                "no NFNT bitmap strike in suitcase (TrueType-only face); "
                "Tier-1 TTF only — render from the .ttf at runtime")
        for res in strikes:
            size, style = size_by_id.get(res.id, (0, 0))
            label = f"{face.lower()}-{size}{STYLE_SUFFIX.get(style, '')}"
            strike = fonts.parse_nfnt(res.data)
            sheet, metrics = fonts.render_strike(strike)
            metrics["face"] = face
            metrics["pointSize"] = size
            metrics["style"] = style
            sheet.save(os.path.join(font_dir, f"{label}.png"))
            with open(os.path.join(font_dir, f"{label}.json"), "w") as fh:
                json.dump(metrics, fh, indent=1, sort_keys=True)
            summary["sheets"][label] = {
                "glyphs": len(metrics["glyphs"]), "size": size, "style": style}
            prov.append({"asset": f"fonts/{label}.png", "source": rel,
                         "type": "NFNT", "id": res.id})
            prov.append({"asset": f"fonts/{label}.json", "source": rel,
                         "type": "NFNT", "id": res.id})
    return summary


def _safe(text: str) -> str:
    return "".join(c if c.isalnum() or c in "-_." else "_" for c in text)


def _icon_name(desc: dict) -> str:
    # Always id-qualify: resource names are not unique (two 'Finder' ics8 exist),
    # and the id keeps every file traceable back to its resource.
    base = _safe(desc["name"]) + "_" if desc["name"] else ""
    return f"{base}{desc['color_type']}_{desc['id']}_{desc['dim']}"


def extract_icons(sysfork: resfork.ResourceFork, out_dir: str, prov: list) -> dict:
    icon_dir = os.path.join(out_dir, "icons")
    os.makedirs(icon_dir, exist_ok=True)
    count = 0
    for desc in icons.extract_icons(sysfork):
        name = _icon_name(desc)
        desc["image"].save(os.path.join(icon_dir, f"{name}.png"))
        prov.append({"asset": f"icons/{name}.png", "source": "System Folder:System",
                     "type": desc["color_type"], "id": desc["id"],
                     "mask": desc["mask_type"]})
        count += 1
    return {"count": count}


def extract_cursors(sysfork: resfork.ResourceFork, out_dir: str, prov: list) -> dict:
    cur_dir = os.path.join(out_dir, "cursors")
    os.makedirs(cur_dir, exist_ok=True)
    hotspots = {}
    for desc in cursors.extract_cursors(sysfork):
        base = _safe(desc["name"]) + "_" if desc["name"] else ""
        name = f"{base}CURS_{desc['id']}"
        desc["image"].save(os.path.join(cur_dir, f"{name}.png"))
        hotspots[name] = {"x": desc["hotspot"][0], "y": desc["hotspot"][1]}
        prov.append({"asset": f"cursors/{name}.png", "source": "System Folder:System",
                     "type": "CURS", "id": desc["id"]})
    with open(os.path.join(cur_dir, "hotspots.json"), "w") as fh:
        json.dump(hotspots, fh, indent=1, sort_keys=True)
    return {"count": len(hotspots)}


def extract_patterns(sysfork: resfork.ResourceFork, out_dir: str, prov: list) -> dict:
    pat_dir = os.path.join(out_dir, "patterns")
    os.makedirs(pat_dir, exist_ok=True)
    result = patterns.extract_patterns(sysfork)
    summary = {"ppat": [], "PAT": []}
    desktop_id = None
    for p in result["ppat"]:
        if "image" not in p:
            summary["ppat"].append({"id": p["id"], "error": p.get("error")})
            continue
        # The 'Mac OS Default' ppat is the default desktop pattern.
        is_desktop = (p.get("name") or "").strip().lower() == "mac os default"
        fname = "desktop.png" if is_desktop else f"ppat_{p['id']}.png"
        p["image"].save(os.path.join(pat_dir, fname))
        if is_desktop:
            desktop_id = p["id"]
        summary["ppat"].append({"id": p["id"], "name": p["name"],
                                "w": p["w"], "h": p["h"], "file": fname})
        prov.append({"asset": f"patterns/{fname}", "source": "System Folder:System",
                     "type": "ppat", "id": p["id"]})
    for p in result["PAT"]:
        fname = f"pat_{p['id']}.png"
        p["image"].save(os.path.join(pat_dir, fname))
        summary["PAT"].append({"id": p["id"], "file": fname})
        prov.append({"asset": f"patterns/{fname}", "source": "System Folder:System",
                     "type": "PAT ", "id": p["id"]})
    summary["desktop_ppat_id"] = desktop_id
    return summary


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, help="live-pull off the anchor worker on this host port")
    ap.add_argument("--cache", default=os.path.join(HERE, ".cache"),
                    help="dir of cached rsrc forks (populated by a live pull)")
    ap.add_argument("--out", default=os.path.join(MIRROR, "assets/platinum-pack"))
    ap.add_argument("--image-id", default="os91-runner.qcow2")
    args = ap.parse_args()

    worker_ver = None
    if args.port:
        h = pull._harness(LAB, args.port)
        try:
            worker_ver = h.version()
        finally:
            h.close()
        pull.pull_forks(LAB, args.port, args.cache)

    cache = {name: os.path.join(args.cache, name) for name in pull.SOURCES}
    for name, path in cache.items():
        if not os.path.exists(path):
            raise SystemExit(f"missing cached fork {path}; run with --port to pull it")

    os.makedirs(args.out, exist_ok=True)
    prov: list = []
    sysfork = resfork.load(cache["System.rsrc"])

    fonts_sum = extract_fonts(cache, args.out, prov)
    icons_sum = extract_icons(sysfork, args.out, prov)
    cursors_sum = extract_cursors(sysfork, args.out, prov)
    patterns_sum = extract_patterns(sysfork, args.out, prov)

    manifest = {
        "pack": "platinum-pack",
        "version": "0.1.0",
        "source_image": args.image_id,
        "worker_version": worker_ver,
        "extracted": datetime.date.today().isoformat(),
        "extractor": "tools/extract-assets/extract.py",
        "clut": "generated system 8-bit CLUT (validated vs guest desktop render)",
        "fonts": fonts_sum,
        "icons": icons_sum,
        "cursors": cursors_sum,
        "patterns": patterns_sum,
        "provenance": sorted(prov, key=lambda p: p["asset"]),
        "copyright": "Apple bitmap/font data — private repo only; do not publish.",
    }
    with open(os.path.join(args.out, "manifest.json"), "w") as fh:
        json.dump(manifest, fh, indent=1, sort_keys=True)

    print(f"pack -> {args.out}")
    print(f"  fonts: {len(fonts_sum['ttf'])} TTF, {len(fonts_sum['sheets'])} sheets")
    print(f"  icons: {icons_sum['count']}  cursors: {cursors_sum['count']}")
    print(f"  patterns: desktop ppat id {patterns_sum['desktop_ppat_id']}, "
          f"{len(patterns_sum['PAT'])} PAT")
    print(f"  provenance rows: {len(prov)}")


if __name__ == "__main__":
    main()
