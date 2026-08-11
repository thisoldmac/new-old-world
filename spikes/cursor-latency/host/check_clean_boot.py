#!/usr/bin/env python3
"""Did OS 9 come up complaining about the last shutdown?

The rig reboots the guest with the Shutdown Manager rather than a QMP
`quit`, precisely so the volume is flushed and unmounted on the way out.
This is the check that says whether that worked - and it is worth having
because the failure is SILENT in every other way: a dirty volume boots
fine, runs fine, and only shows up as a Disk First Aid modal that a
headless run never sees, on some later clone.

The guest is the oracle: a screenshot, and the alert is a light
rectangle in the top-left quadrant of an otherwise dark desktop. Rather
than OCR it, this reports the shape and leaves the judgement visible -
it prints the path so a person (or a later step) can look.
"""
import argparse
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
LAB = os.path.abspath(os.path.join(HERE, "..", ".."))
while LAB != "/" and not os.path.isdir(os.path.join(LAB, "mcp-classic")):
    LAB = os.path.dirname(LAB)
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness  # noqa: E402

ap = argparse.ArgumentParser()
ap.add_argument("--port", type=int, default=1407)
ap.add_argument("--out", default="/tmp/cursor-rig-boot.png")
a = ap.parse_args()

h = Harness(host="127.0.0.1", port=a.port, expect_backing={"worker", "harness"})
png, meta = h.capture_full(depth=8)
with open(a.out, "wb") as fh:
    fh.write(png)
print(f"  boot screenshot: {a.out} ({meta.get('width')}x{meta.get('height')})")
print("  look for an alert: 'Your computer did not shut down properly' means "
      "the Shutdown Manager path did NOT flush, and the cold cycle is lying "
      "to you.")
