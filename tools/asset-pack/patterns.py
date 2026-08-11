"""Pattern extraction: 'PAT ' (8x8 1-bit) and 'ppat' (colour PixPat).

'PAT ' is 8 bytes: an 8x8 one-bit tile (1 == black). 'ppat' is a PixPat whose
patType 1 carries a PixMap + indexed pixel data + an embedded ColorTable; we
parse the PixMap header, read the indexed rows, and resolve colours through the
embedded table. patType 0 falls back to the 8-byte pat1Data tile.
"""

from __future__ import annotations

import struct

from PIL import Image

import resfork


def render_pat(body: bytes) -> Image.Image:
    """8x8 one-bit pattern -> RGB tile (black/white)."""
    img = Image.new("RGB", (8, 8), (255, 255, 255))
    px = img.load()
    for row in range(8):
        byte = body[row]
        for col in range(8):
            if (byte >> (7 - col)) & 1:
                px[col, row] = (0, 0, 0)
    return img


def _parse_pixmap(body: bytes, off: int) -> dict:
    (base, row_bytes, top, left, bottom, right, ver, pack_type, pack_size,
     hres, vres, pixel_type, pixel_size, cmp_count, cmp_size, plane_bytes,
     pm_table, pm_reserved) = struct.unpack_from(">IHhhhhHHIIIHHHHIII", body, off)
    return {
        "rowBytes": row_bytes & 0x3FFF,
        "w": right - left, "h": bottom - top,
        "pixelSize": pixel_size, "pmTable": pm_table,
    }


def _parse_color_table(body: bytes, off: int) -> dict[int, tuple[int, int, int]]:
    _seed, _flags, size = struct.unpack_from(">IHH", body, off)
    out = {}
    p = off + 8
    for _ in range(size + 1):
        value, r, g, b = struct.unpack_from(">HHHH", body, p)
        p += 8
        out[value] = (r >> 8, g >> 8, b >> 8)
    return out


def render_ppat(body: bytes) -> tuple[Image.Image, dict]:
    """Render a 'ppat' to an RGB tile. Returns (image, info)."""
    pat_type = struct.unpack_from(">H", body, 0)[0]
    pat_map = struct.unpack_from(">I", body, 2)[0]
    pat_data = struct.unpack_from(">I", body, 6)[0]
    if pat_type == 0 or pat_map == 0:
        tile = render_pat(body[18:26])           # pat1Data
        return tile, {"patType": pat_type, "w": 8, "h": 8, "pixelSize": 1}

    pm = _parse_pixmap(body, pat_map)
    ctab = _parse_color_table(body, pm["pmTable"])
    w, h, ps, rb = pm["w"], pm["h"], pm["pixelSize"], pm["rowBytes"]
    img = Image.new("RGB", (w, h), (255, 255, 255))
    px = img.load()
    for row in range(h):
        base = pat_data + row * rb
        for col in range(w):
            if ps == 8:
                idx = body[base + col]
            elif ps == 4:
                b = body[base + (col >> 1)]
                idx = (b >> 4) if (col & 1) == 0 else (b & 0xF)
            elif ps == 1:
                b = body[base + (col >> 3)]
                idx = (b >> (7 - (col & 7))) & 1
            elif ps == 2:
                b = body[base + (col >> 2)]
                idx = (b >> (6 - 2 * (col & 3))) & 3
            else:
                idx = 0
            px[col, row] = ctab.get(idx, (0, 0, 0))
    return img, {"patType": pat_type, "w": w, "h": h, "pixelSize": ps}


def extract_patterns(fork: resfork.ResourceFork) -> dict:
    ppats, pats = [], []
    for res in fork.of_type("ppat"):
        try:
            img, info = render_ppat(res.data)
            ppats.append({"id": res.id, "name": res.name, "image": img, **info})
        except Exception as exc:                 # keep going; record the failure
            ppats.append({"id": res.id, "name": res.name, "error": str(exc)})
    for res in fork.of_type("PAT "):
        pats.append({"id": res.id, "name": res.name, "image": render_pat(res.data)})
    return {"ppat": ppats, "PAT": pats}
