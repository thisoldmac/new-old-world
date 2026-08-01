"""iconpack — extract per-app icons from the guest's own resource forks.

Digs the real "vanilla+" icons out of the running OS 9 guest: enumerate
Apple's apps + control panels, pull each rsrc fork (read-only, via the anchor),
parse the bundle (BNDL -> FREF -> icl8/ICN#), and emit one composited PNG per
`(creator, fileType)`. The creator comes from the app's own BNDL, so no
list-verb creator field is needed.

Keying: `(creator, type)`. The app's own icon is `(creator, 'APPL')`; each
document type it owns is `(creator, <fileType>)`. The mirror renders an alias
(type `adrp`) or an app (type `APPL`) with `(creator, 'APPL')`, a document with
`(creator, type)`, falling back to the generic set.

Apple data — private repo only, never published (same rule as platinum-pack).
"""
from __future__ import annotations

import json
import os
import struct
import sys

from PIL import Image

sys.path.insert(0, os.path.dirname(__file__))
import icons
import resfork

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.abspath(os.path.join(HERE, "..", ".."))   # this repo
LAB = os.path.abspath(os.path.join(MIRROR, ".."))          # lab checkout (harness)
OUT = os.path.join(MIRROR, "assets/platinum-pack/appicons")

# Vanilla+ roots to sweep for APPL files, and Control Panels for cdev.
APP_ROOTS = [
    "Macintosh HD:Applications (Mac OS 9):",
    "Macintosh HD:Apple Extras:",
]
CDEV_ROOT = "Macintosh HD:System Folder:Control Panels:"
# Skip obviously third-party / Microsoft trees (generic is fine for those).
SKIP = ("Internet Explorer", "Outlook Express", "Microsoft", "Iomega")


def harness(port=1400):
    sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
    from timbottu_mcp_classic.harness import Harness
    return Harness(host="127.0.0.1", port=port, expect_backing={"worker"},
                   timeout=120)


def sweep(h, root, want_type, depth=0, maxd=3, acc=None):
    acc = acc if acc is not None else []
    try:
        r = h.request("list", {"path": root})
    except Exception:
        return acc
    for it in r.get("items", []):
        name = it.get("name", "")
        if any(s in name for s in SKIP):
            continue
        full = root + name
        if it.get("kind") == "file" and it.get("type") == want_type:
            acc.append(full)
        elif it.get("kind") == "folder" and depth < maxd:
            if any(s in name for s in SKIP):
                continue
            sweep(h, full + ":", want_type, depth + 1, maxd, acc)
    return acc


def parse_bundle(fork: resfork.ResourceFork):
    """Return (creator, {fileType: resID}) from the BNDL/FREF, or None."""
    bndls = fork.of_type("BNDL")
    if not bndls:
        return None
    d = bndls[0].data
    creator = d[0:4]
    _, count_m1 = struct.unpack(">Hh", d[4:8])
    off = 8
    icn_local_to_res: dict[int, int] = {}
    fref_local_to_res: dict[int, int] = {}
    for _ in range(count_m1 + 1):
        typ = d[off:off + 4]
        cnt_m1 = struct.unpack(">h", d[off + 4:off + 6])[0]
        off += 6
        table = {}
        for _ in range(cnt_m1 + 1):
            lid, rid = struct.unpack(">hh", d[off:off + 4])
            off += 4
            table[lid] = rid
        if typ in (b"ICN#", b"icl8"):
            icn_local_to_res.update(table)
        elif typ == b"FREF":
            fref_local_to_res.update(table)
    # FREF resID -> (fileType, iconLocalID); map fileType -> icon resID.
    type_to_res: dict[bytes, int] = {}
    for local, fref_res in fref_local_to_res.items():
        fref = fork.get("FREF", fref_res)
        if not fref or len(fref.data) < 6:
            continue
        ftype = fref.data[0:4]
        icon_local = struct.unpack(">h", fref.data[4:6])[0]
        res = icn_local_to_res.get(icon_local)
        if res is not None:
            type_to_res[ftype] = res
    return creator, type_to_res


def compose(fork: resfork.ResourceFork, res_id: int) -> Image.Image | None:
    icl8 = fork.get("icl8", res_id)
    if not icl8 or len(icl8.data) < 1024:
        return None
    mask = fork.get("ICN#", res_id)
    return icons.render_icon(icl8.data, mask.data if mask else None, 32)


def ostype_key(raw: bytes) -> str:
    """A filesystem-safe key for an OSType: printable ASCII kept, else hex."""
    if all(32 < b < 127 and chr(b) not in "/\\:" for b in raw):
        return raw.decode("ascii")
    return "x" + raw.hex()


def main():
    os.makedirs(OUT, exist_ok=True)
    h = harness()
    apps = []
    for root in APP_ROOTS:
        apps += sweep(h, root, "APPL")
    # OS 9 control panels are type 'APPC' (a few legacy ones are 'cdev').
    cdevs = sweep(h, CDEV_ROOT, "APPC") + sweep(h, CDEV_ROOT, "cdev")
    targets = apps + cdevs
    print(f"{len(apps)} apps + {len(cdevs)} control panels to scan")

    manifest = {}
    written = 0
    for path in targets:
        try:
            f = h.pull_file(path, fork="rsrc", pipeline=4)
        except Exception as e:
            print(f"  SKIP {path.split(':')[-1]}: pull {e}")
            continue
        if not f.rsrc_fork:
            continue
        try:
            fork = resfork.ResourceFork(f.rsrc_fork)
            parsed = parse_bundle(fork)
        except Exception as e:
            print(f"  SKIP {path.split(':')[-1]}: parse {e}")
            continue
        if not parsed:
            continue
        creator, type_to_res = parsed
        ckey = ostype_key(creator)
        for ftype, res_id in type_to_res.items():
            img = compose(fork, res_id)
            if img is None:
                continue
            tkey = ostype_key(ftype)
            fname = f"{ckey}__{tkey}.png"
            img.save(os.path.join(OUT, fname))
            manifest[f"{ckey}/{tkey}"] = {
                "asset": f"appicons/{fname}", "creator": ckey,
                "type": tkey, "source": path, "resId": res_id,
            }
            written += 1
        print(f"  {path.split(':')[-1]}: creator {ckey}, "
              f"{len(type_to_res)} type icons")
    h.close()

    with open(os.path.join(OUT, "manifest.json"), "w") as fh:
        json.dump({"pack": "appicons", "note": "Apple app icons by "
                   "(creator,type); private repo only", "icons": manifest},
                  fh, indent=1, sort_keys=True)
    print(f"wrote {written} icons for {len(set(k.split('/')[0] for k in manifest))} creators")


if __name__ == "__main__":
    main()
