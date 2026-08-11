#!/usr/bin/env python3
"""Rename the file inside a MacBinary header (name field + CRC).

The decoded name is what Rumpus writes and what prefs key off, so a chip
build must carry its chip name INSIDE the .bin, not just on the file.
CRC-16/XMODEM over bytes 0..123, stored big-endian at 124.
"""
import sys

def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for b in data:
        crc ^= b << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if (crc & 0x8000) else (crc << 1)
            crc &= 0xFFFF
    return crc

src, dst, new_name = sys.argv[1], sys.argv[2], sys.argv[3]
raw = bytearray(open(src, "rb").read())
name = new_name.encode("mac_roman")
assert 1 <= len(name) <= 63
old = raw[2 : 2 + raw[1]].decode("mac_roman")
raw[1] = len(name)
raw[2:65] = name.ljust(63, b"\x00")
raw[124:126] = crc16_xmodem(bytes(raw[0:124])).to_bytes(2, "big")
open(dst, "wb").write(raw)
print(f"renamed '{old}' -> '{new_name}', CRC {raw[124]:02X}{raw[125]:02X}")
