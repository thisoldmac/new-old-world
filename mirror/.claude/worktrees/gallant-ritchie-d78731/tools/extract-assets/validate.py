#!/usr/bin/env python3
"""Tier-2 acceptance: compare a sheet-rendered line against a live-guest capture.

Captures the guest framebuffer via the anchor worker, crops a known on-screen
text label, binarises it, and computes the best-shift intersection-over-union
against the same string rendered from a pack glyph sheet. A pixel-honest strike
scores IoU 1.0.

The default case is the Finder icon label "TBTRunner" (rendered by the guest in
Geneva 10), verified 2026-07-16 at IoU 1.0. Point --crop/--text/--label at any
other on-screen bitmap-text sample to check a different strike.
"""

from __future__ import annotations

import argparse
import os
import sys

import numpy as np
from PIL import Image

import render_string

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.abspath(os.path.join(HERE, "..", ".."))   # this repo
LAB = os.path.abspath(os.path.join(MIRROR, ".."))          # lab checkout (harness)
PACK = os.path.join(MIRROR, "assets/platinum-pack")


def capture(port: int) -> Image.Image:
    sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
    from timbottu_mcp_classic.harness import Harness
    h = Harness(host="127.0.0.1", port=port, expect_backing={"worker"}, timeout=60)
    try:
        png, _meta = h.capture_full(depth=8)
    finally:
        h.close()
    import io
    return Image.open(io.BytesIO(png)).convert("L")


def _ink_bbox(mask: np.ndarray) -> np.ndarray:
    ys, xs = np.where(mask)
    return mask[ys.min():ys.max() + 1, xs.min():xs.max() + 1]


def guest_label_ink(screen: Image.Image, crop: tuple[int, int, int, int]) -> np.ndarray:
    x0, y0, x1, y1 = crop
    band = np.array(screen)[y0:y1, x0:x1]
    col_light = (band > 170).sum(axis=0)
    xs = np.where(col_light >= 3)[0]
    box = band[:, xs.min():xs.max() + 1]
    return _ink_bbox((box < 128).astype(np.uint8))


def best_iou(a: np.ndarray, b: np.ndarray) -> tuple[float, int, int]:
    best = (0.0, 0, 0)
    for dy in range(-4, 5):
        for dx in range(-6, 7):
            h = max(a.shape[0], b.shape[0]) + 10
            w = max(a.shape[1], b.shape[1]) + 14
            ca = np.zeros((h, w), np.uint8)
            cb = np.zeros((h, w), np.uint8)
            ca[5:5 + a.shape[0], 7:7 + a.shape[1]] = a
            cb[5 + dy:5 + dy + b.shape[0], 7 + dx:7 + dx + b.shape[1]] = b
            inter = int(np.sum((ca == 1) & (cb == 1)))
            union = int(np.sum((ca == 1) | (cb == 1)))
            iou = inter / union if union else 0.0
            if iou > best[0]:
                best = (round(iou, 4), dx, dy)
    return best


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--label", default="geneva-10", help="pack sheet label")
    ap.add_argument("--text", default="TBTRunner")
    ap.add_argument("--crop", default="430,124,540,137",
                    help="x0,y0,x1,y1 of the on-screen label band")
    ap.add_argument("--min-iou", type=float, default=0.95)
    args = ap.parse_args()

    crop = tuple(int(v) for v in args.crop.split(","))
    screen = capture(args.port)
    gb = guest_label_ink(screen, crop)

    rendered = render_string.render_line(PACK, args.label, args.text)
    mb = _ink_bbox((np.array(rendered)[:, :, 3] > 0).astype(np.uint8))

    iou, dx, dy = best_iou(gb, mb)
    print(f"guest {gb.shape} vs {args.label} {mb.shape}: IoU={iou} (shift {dx},{dy})")
    if iou < args.min_iou:
        raise SystemExit(f"FAIL: IoU {iou} < {args.min_iou}")
    print("PASS")


if __name__ == "__main__":
    main()
