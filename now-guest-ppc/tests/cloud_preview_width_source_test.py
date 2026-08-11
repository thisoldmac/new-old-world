#!/usr/bin/env python3
"""Prevent target-width overflow in peer-controlled preview geometry.

The PowerPC guest has a signed 32-bit ``long`` while the native tests run on
a 64-bit host.  A host value test therefore cannot reproduce the multiplication
wrap that can make a tiny allocation satisfy a huge row geometry.  This guard
pins the required operation order in the parser: bound the announced byte count
first, then validate geometry with division/remainder and no row-by-height
multiplication.
"""

from pathlib import Path


SOURCE = (
    Path(__file__).resolve().parents[1] / "src" / "cloud" / "cloud_preview.c"
).read_text()


start = SOURCE.index(
    "int cloud_preview_parse_begin(const char *reply, CloudPreviewBegin *out)"
)
end = SOURCE.index("long cloud_preview_ask_depth", start)
body = SOURCE[start:end]

if "out->row_bytes * out->height" in body:
    raise SystemExit(
        "preview.begin multiplies peer-controlled rowBytes and height in a "
        "32-bit signed long; validate the bounded total by division instead"
    )

cap_check = body.find("out->bytes > kCloudPreviewMaxBytes")
division_check = body.find("out->bytes / out->height")
remainder_check = body.find("out->bytes % out->height")
if cap_check < 0 or division_check < 0 or remainder_check < 0:
    raise SystemExit("preview.begin is missing bounded division geometry checks")
if cap_check > division_check:
    raise SystemExit("preview.begin must bound bytes before geometry arithmetic")

print("ok")
