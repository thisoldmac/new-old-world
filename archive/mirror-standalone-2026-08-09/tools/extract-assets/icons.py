"""Icon extraction: icl8/ics8 (8-bit colour) composited with ICN#/ics# masks.

`icl8` is a 32x32 array of 1024 CLUT indices; `ics8` is 16x16 (256 bytes). The
matching `ICN#`/`ics#` resource of the same id carries two 1-bit planes: plane 0
the icon bitmap, plane 1 the transparency mask. We composite the 8-bit colour
against the mask so transparent pixels drop out (RGBA).
"""

from __future__ import annotations

from PIL import Image

import clut
import resfork

_CLUT = clut.SYSTEM_CLUT


def _mask_plane(icn_body: bytes, dim: int) -> list[int]:
    """Return the mask (second 1-bit plane) as a flat 0/1 list of dim*dim."""
    plane_bytes = (dim * dim) // 8
    mask = icn_body[plane_bytes:plane_bytes * 2]
    bits = []
    for row in range(dim):
        for col in range(dim):
            bit_index = row * dim + col
            byte = mask[bit_index >> 3]
            bits.append((byte >> (7 - (bit_index & 7))) & 1)
    return bits


def render_icon(color_body: bytes, mask_body: bytes | None, dim: int) -> Image.Image:
    """Composite an 8-bit icon (icl8/ics8) with its mask into RGBA dim x dim."""
    img = Image.new("RGBA", (dim, dim), (0, 0, 0, 0))
    px = img.load()
    mask = _mask_plane(mask_body, dim) if mask_body else [1] * (dim * dim)
    for i in range(dim * dim):
        r, g, b = _CLUT[color_body[i]]
        a = 255 if mask[i] else 0
        px[i % dim, i // dim] = (r, g, b, a)
    return img


def extract_icons(fork: resfork.ResourceFork) -> list[dict]:
    """Yield descriptors for every icl8/ics8 with its composited image."""
    out = []
    for color_type, mask_type, dim in (("icl8", "ICN#", 32), ("ics8", "ics#", 16)):
        for res in fork.of_type(color_type):
            mask = fork.get(mask_type, res.id)
            img = render_icon(res.data, mask.data if mask else None, dim)
            out.append({
                "id": res.id,
                "name": res.name,
                "dim": dim,
                "color_type": color_type,
                "mask_type": mask_type if mask else None,
                "image": img,
            })
    return out
