#!/usr/bin/env python3
"""Stamp a MacBinary's internal file name.

A classic HFS name may contain spaces; a CMake target name may not, and
Retro68's add_application uses the target name for the MacBinary the
build emits. So the on-disk (and thus classic process) name is taken from
the CMake target unless we override it here - which matters because the
guest keys its canonical preferences off that process name (prefs.c ::
prefs_spec). This copies a built .bin to a new one whose MacBinary header
carries the given name, so the canonical deploy artifact can be
"New Old World" while the build target stays a plain identifier.

MacBinary header (the fields we touch):
  byte 1        name length (1..63)
  bytes 2..64   name, zero-padded
  bytes 124..125  CRC-16/XMODEM over bytes 0..123
Everything else - forks, type/creator, lengths - is copied untouched.

Usage: name_macbinary.py <in.bin> <out.bin> "<Name>"
"""
import sys


def crc16_xmodem(data: bytes) -> int:
    """CRC-16/CCITT (XMODEM): poly 0x1021, init 0, no reflection. The
    checksum MacBinary II stores over the first 124 header bytes."""
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) & 0xFFFF if crc & 0x8000 \
                else (crc << 1) & 0xFFFF
    return crc


def stamp_name(raw: bytes, name: str) -> bytes:
    encoded = name.encode("mac_roman")
    if not 1 <= len(encoded) <= 63:
        raise ValueError(f"name must be 1..63 MacRoman bytes, got {len(encoded)}")
    if len(raw) < 128 or raw[0] != 0:
        raise ValueError("not a MacBinary file (bad header)")
    out = bytearray(raw)
    out[1] = len(encoded)
    out[2:65] = encoded + b"\x00" * (63 - len(encoded))
    crc = crc16_xmodem(bytes(out[0:124]))
    out[124] = (crc >> 8) & 0xFF
    out[125] = crc & 0xFF
    return bytes(out)


def main(argv):
    if len(argv) != 4:
        sys.stderr.write("usage: name_macbinary.py <in.bin> <out.bin> <name>\n")
        return 64
    src, dst, name = argv[1], argv[2], argv[3]
    with open(src, "rb") as f:
        raw = f.read()
    with open(dst, "wb") as f:
        f.write(stamp_name(raw, name))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
