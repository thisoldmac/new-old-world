#!/usr/bin/env python3
"""A failed replacement must leave the last complete ROM dump intact."""

from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "now-guest-ppc/src/census/rom_dump.c").read_text()

required = (
    "New Old World ROM.tmp",
    "FSpExchangeFiles(&temporary_spec, &spec)",
    "FSpRename(&temporary_spec, name)",
)
for token in required:
    if token not in SOURCE:
        raise SystemExit(f"ROM dump atomic publication lost: {token}")
if "the ROM write failed" not in SOURCE or "FSpDelete(&temporary_spec)" not in SOURCE:
    raise SystemExit("failed ROM writes do not clean only the temporary artifact")
