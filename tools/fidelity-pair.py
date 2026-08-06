#!/usr/bin/env python3
"""Put the host's render and the machine's own pixels side by side, for
one window, at the same scale — the only form in which a fidelity
judgement is worth anything.

    tools/fidelity-pair.py --sweep /private/tmp/fsweep-out \\
        --renders /private/tmp/renders --out /private/tmp/pairs

For every target in the sweep's summary it crops `<label>-guest.ppm` to
that window's rect (from `<label>-scene.json`, which is the scene the
capture's address came from) and writes `<label>-pair.png`: guest left,
render right.

THE CROP IS THE WHOLE WINDOW, frame included, because CHROME is one of
the rubric's axes and a crop to the content rect would put it out of
reach. The render is the host's whole window too.

No third-party imaging: PPM is three bytes a pixel and PNG is written by
hand, so this runs wherever python3 does.
"""

import argparse
import json
import os
import struct
import sys
import zlib


def read_ppm(path):
    """P6 binary PPM, as QEMU's screendump writes it."""
    with open(path, "rb") as handle:
        blob = handle.read()
    if not blob.startswith(b"P6"):
        raise ValueError("%s is not a P6 PPM" % path)
    fields, pos = [], 2
    while len(fields) < 3:
        while pos < len(blob) and blob[pos:pos + 1].isspace():
            pos += 1
        if blob[pos:pos + 1] == b"#":
            while blob[pos:pos + 1] not in (b"\n", b""):
                pos += 1
            continue
        start = pos
        while pos < len(blob) and not blob[pos:pos + 1].isspace():
            pos += 1
        fields.append(int(blob[start:pos]))
    pos += 1
    width, height, _ = fields
    return width, height, blob[pos:pos + width * height * 3]


def write_png(path, width, height, rgb):
    raw = b"".join(b"\x00" + rgb[y * width * 3:(y + 1) * width * 3]
                   for y in range(height))

    def chunk(tag, data):
        return (struct.pack(">I", len(data)) + tag + data
                + struct.pack(">I", zlib.crc32(tag + data) & 0xFFFFFFFF))

    with open(path, "wb") as handle:
        handle.write(b"\x89PNG\r\n\x1a\n")
        handle.write(chunk(b"IHDR", struct.pack(">IIBBBBB", width, height,
                                                8, 2, 0, 0, 0)))
        handle.write(chunk(b"IDAT", zlib.compress(raw, 6)))
        handle.write(chunk(b"IEND", b""))


def read_png(path):
    """Enough PNG to read back what RenderShot wrote: 8-bit RGB or RGBA,
    no interlace, no palette."""
    with open(path, "rb") as handle:
        blob = handle.read()
    pos, idat, meta = 8, b"", None
    while pos < len(blob):
        length = struct.unpack(">I", blob[pos:pos + 4])[0]
        tag = blob[pos + 4:pos + 8]
        data = blob[pos + 8:pos + 8 + length]
        if tag == b"IHDR":
            meta = struct.unpack(">IIBBBBB", data)
        elif tag == b"IDAT":
            idat += data
        elif tag == b"IEND":
            break
        pos += 12 + length
    width, height, depth, colour, _, _, interlace = meta
    if depth != 8 or interlace or colour not in (2, 6):
        raise ValueError("%s: unsupported PNG (%s)" % (path, meta))
    channels = 3 if colour == 2 else 4
    raw = zlib.decompress(idat)
    stride = width * channels
    out = bytearray(width * height * 3)
    prior = bytearray(stride)
    pos = 0
    for y in range(height):
        filt = raw[pos]
        line = bytearray(raw[pos + 1:pos + 1 + stride])
        pos += 1 + stride
        for x in range(stride):
            a = line[x - channels] if x >= channels else 0
            b = prior[x]
            c = prior[x - channels] if x >= channels else 0
            if filt == 1:
                line[x] = (line[x] + a) & 255
            elif filt == 2:
                line[x] = (line[x] + b) & 255
            elif filt == 3:
                line[x] = (line[x] + (a + b) // 2) & 255
            elif filt == 4:
                p = a + b - c
                pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
                pred = a if (pa <= pb and pa <= pc) else (b if pb <= pc else c)
                line[x] = (line[x] + pred) & 255
        prior = line
        for x in range(width):
            out[(y * width + x) * 3:(y * width + x) * 3 + 3] = \
                line[x * channels:x * channels + 3]
    return width, height, bytes(out)


def crop(width, height, rgb, box):
    left, top, right, bottom = box
    left, top = max(0, left), max(0, top)
    right, bottom = min(width, right), min(height, bottom)
    out = bytearray()
    for y in range(top, bottom):
        out += rgb[(y * width + left) * 3:(y * width + right) * 3]
    return right - left, bottom - top, bytes(out)


def beside(left_img, right_img, gap=16):
    (lw, lh, lp), (rw, rh, rp) = left_img, right_img
    width, height = lw + gap + rw, max(lh, rh)
    out = bytearray(b"\x20" * (width * height * 3))
    for y in range(lh):
        out[(y * width) * 3:(y * width + lw) * 3] = lp[y * lw * 3:(y + 1) * lw * 3]
    for y in range(rh):
        start = (y * width + lw + gap) * 3
        out[start:start + rw * 3] = rp[y * rw * 3:(y + 1) * rw * 3]
    return width, height, bytes(out)


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--sweep", required=True)
    parser.add_argument("--renders", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--pad", type=int, default=24,
                        help="pixels of desktop around the window rect, so "
                             "the frame and drop shadow are in the crop")
    args = parser.parse_args()
    os.makedirs(args.out, exist_ok=True)

    with open(os.path.join(args.sweep, "sweep-summary.json")) as handle:
        summary = json.load(handle)
    for result in summary["results"]:
        label = result["label"]
        if result.get("status") != "ok":
            print("%-22s skipped (%s)" % (label, result.get("status")))
            continue
        ppm = os.path.join(args.sweep, "%s-guest.ppm" % label)
        png = os.path.join(args.renders, "%s.png" % label)
        if not os.path.exists(ppm) or not os.path.exists(png):
            print("%-22s missing %s" % (label, "screendump"
                                        if not os.path.exists(ppm)
                                        else "render"))
            continue
        rect = result.get("rect") or {}
        width, height, pixels = read_ppm(ppm)
        box = (rect.get("l", 0) - args.pad, rect.get("t", 0) - args.pad,
               rect.get("r", width) + args.pad,
               rect.get("b", height) + args.pad)
        guest = crop(width, height, pixels, box)
        render = read_png(png)
        pair = beside(guest, render)
        out = os.path.join(args.out, "%s-pair.png" % label)
        write_png(out, *pair)
        print("%-22s guest %dx%d | render %dx%d -> %s"
              % (label, guest[0], guest[1], render[0], render[1], out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
