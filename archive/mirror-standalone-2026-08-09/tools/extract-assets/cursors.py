"""Cursor extraction: 'CURS' = 16x16 1-bit data + 1-bit mask + hotspot.

Layout (Inside Macintosh: Imaging With QuickDraw, Cursor): 32 bytes data,
32 bytes mask, then a Point hotSpot (v, h as 16-bit each). Rendering rule:
where mask=1 the pixel is opaque and its colour is black if data=1 else white;
where mask=0 the pixel is transparent.
"""

from __future__ import annotations

import struct

from PIL import Image

import resfork

_DIM = 16


def _bits(plane: bytes) -> list[int]:
    out = []
    for i in range(_DIM * _DIM):
        out.append((plane[i >> 3] >> (7 - (i & 7))) & 1)
    return out


def render_cursor(body: bytes) -> tuple[Image.Image, tuple[int, int]]:
    data = _bits(body[0:32])
    mask = _bits(body[32:64])
    hv, hh = struct.unpack_from(">hh", body, 64) if len(body) >= 68 else (0, 0)
    img = Image.new("RGBA", (_DIM, _DIM), (0, 0, 0, 0))
    px = img.load()
    for i in range(_DIM * _DIM):
        if mask[i]:
            v = 0 if data[i] else 255
            px[i % _DIM, i // _DIM] = (v, v, v, 255)
        elif data[i]:
            # data outside the mask still draws black on classic Mac (XOR),
            # but for a static asset we keep it opaque black so the shape is whole
            px[i % _DIM, i // _DIM] = (0, 0, 0, 255)
    return img, (hh, hv)   # hotspot as (x, y)


def extract_cursors(fork: resfork.ResourceFork) -> list[dict]:
    out = []
    for res in fork.of_type("CURS"):
        img, hot = render_cursor(res.data)
        out.append({
            "id": res.id, "name": res.name, "image": img, "hotspot": hot,
        })
    return out
