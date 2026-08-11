#!/usr/bin/env python3
"""Validate and print the identity carried by a MacBinary envelope."""

from __future__ import annotations

import argparse
import struct
import sys
from pathlib import Path


def crc16_xmodem(data: bytes) -> int:
    crc = 0
    for byte in data:
        crc ^= byte << 8
        for _ in range(8):
            crc = ((crc << 1) ^ 0x1021) if crc & 0x8000 else crc << 1
            crc &= 0xFFFF
    return crc


def padded(length: int) -> int:
    return (length + 127) & ~127


def parse(path: Path) -> dict[str, object]:
    blob = path.read_bytes()
    if len(blob) < 128:
        raise ValueError("shorter than the 128-byte MacBinary header")
    if blob[0] != 0 or not 1 <= blob[1] <= 63:
        raise ValueError("invalid zero byte or internal-name length")
    stored_crc = struct.unpack(">H", blob[124:126])[0]
    actual_crc = crc16_xmodem(blob[:124])
    if stored_crc != actual_crc:
        raise ValueError(
            f"header CRC mismatch: stored {stored_crc:04x}, actual {actual_crc:04x}")

    name = blob[2 : 2 + blob[1]].decode("mac_roman")
    file_type = blob[65:69].decode("mac_roman")
    creator = blob[69:73].decode("mac_roman")
    data_length = struct.unpack(">I", blob[83:87])[0]
    resource_length = struct.unpack(">I", blob[87:91])[0]
    accounted = 128 + padded(data_length) + padded(resource_length)
    if len(blob) < accounted:
        raise ValueError(
            f"truncated forks: header accounts for {accounted} bytes, file has {len(blob)}")
    return {
        "name": name,
        "type": file_type,
        "creator": creator,
        "data": data_length,
        "resource": resource_length,
        "bytes": len(blob),
        "crc": f"{stored_crc:04x}",
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--expect-name")
    parser.add_argument("--expect-type")
    parser.add_argument("--expect-creator")
    args = parser.parse_args()
    try:
        identity = parse(args.path)
        for key, expected in (
            ("name", args.expect_name),
            ("type", args.expect_type),
            ("creator", args.expect_creator),
        ):
            if expected is not None and identity[key] != expected:
                raise ValueError(
                    f"expected {key} {expected!r}, found {identity[key]!r}")
    except (OSError, UnicodeError, ValueError) as error:
        print(f"macbinary-identity: {args.path}: {error}", file=sys.stderr)
        return 1

    for key in ("name", "type", "creator", "data", "resource", "bytes", "crc"):
        print(f"{key}={identity[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
