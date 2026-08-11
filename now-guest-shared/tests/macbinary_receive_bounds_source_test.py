#!/usr/bin/env python3
"""Pin target-width decoding and subtraction-form receive bounds."""

from pathlib import Path


root = Path(__file__).parents[2]
decoder = (root / "now-guest-shared/src/macbinary_lengths.c").read_text()
ppc = (root / "now-guest-ppc/src/files/fileshare.c").read_text()
m68k = (root / "now-guest-68k/src/files/n68_putrx.c").read_text()

assert "((unsigned long)p[0] << 24)" in decoder, (
    "MacBinary bytes must be promoted to unsigned before a 24-bit shift"
)
assert "((long)p[0] << 24)" not in decoder, (
    "signed 32-bit shifts are undefined when the fork length has its high bit set"
)
assert "len > rx->expected - rx->received" in ppc, (
    "the PPC receiver must reject surplus before adding signed byte counts"
)
assert "len > rx->offer.bytes - rx->received" in m68k, (
    "the 68K receiver must reject surplus before adding signed byte counts"
)
assert "rx->received + len >" not in ppc + m68k, (
    "an overflow-prone addition must not be the receive bound"
)
