#!/usr/bin/env python3
"""Keep a guest-initiated stream on the same Native-depth policy as host UI."""

from pathlib import Path
import re

ROOT = Path(__file__).resolve().parents[2]
WIRE = (ROOT / "now-guest-ppc/src/core/wire.c").read_text()

match = re.search(
    r"int now_wire_stream_request\(.*?\n\}\n\nBoolean now_wire_stream_active",
    WIRE,
    re.DOTALL,
)
if match is None:
    raise SystemExit("could not isolate now_wire_stream_request")

body = match.group(0)
if '"{\\"type\\":\\"stream.request\\",\\"depth\\":%d}"' not in body:
    raise SystemExit("stream.request no longer sends an explicit depth")
if not re.search(r'"\{\\"type\\":\\"stream\.request.*?\n\s*0\);', body, re.DOTALL):
    raise SystemExit("guest-initiated stream did not request Native depth sentinel 0")
if "prefs.shot_depth" in body:
    raise SystemExit("persisted 8-bit preference still overrides Native streaming")
