#!/usr/bin/env python3
"""Validate and print the identity carried by a MacBinary envelope."""

from __future__ import annotations

import argparse
import ctypes
import os
import struct
import sys
import tempfile
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


def decode(path: Path) -> tuple[dict[str, object], bytes, bytes, bytes]:
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
    resource_start = 128 + padded(data_length)
    finder_info = bytearray(32)
    finder_info[0:4] = blob[65:69]
    finder_info[4:8] = blob[69:73]
    finder_info[8] = blob[73]
    finder_info[9] = blob[101]
    identity = {
        "name": name,
        "type": file_type,
        "creator": creator,
        "data": data_length,
        "resource": resource_length,
        "bytes": len(blob),
        "crc": f"{stored_crc:04x}",
    }
    return (
        identity,
        blob[128 : 128 + data_length],
        blob[resource_start : resource_start + resource_length],
        bytes(finder_info),
    )


def parse(path: Path) -> dict[str, object]:
    return decode(path)[0]


def install_native(path: Path, directory: Path) -> Path:
    identity, data_fork, resource_fork, finder_info = decode(path)
    if not directory.is_dir():
        raise ValueError(f"installation directory does not exist: {directory}")
    destination = directory / str(identity["name"])
    descriptor, temporary_name = tempfile.mkstemp(prefix=".now-", dir=directory)
    temporary = Path(temporary_name)
    try:
        with os.fdopen(descriptor, "wb") as stream:
            stream.write(data_fork)
        if resource_fork:
            with open(str(temporary) + "/..namedfork/rsrc", "wb") as stream:
                stream.write(resource_fork)
        libc = ctypes.CDLL(None, use_errno=True)
        setxattr = libc.setxattr
        setxattr.argtypes = (
            ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
            ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int)
        finder_buffer = ctypes.create_string_buffer(finder_info)
        if setxattr(
            os.fsencode(temporary), b"com.apple.FinderInfo",
            finder_buffer, len(finder_info), 0, 0) != 0:
            error = ctypes.get_errno()
            raise OSError(error, os.strerror(error), temporary)
        os.replace(temporary, destination)
    except Exception:
        try:
            temporary.unlink()
        except FileNotFoundError:
            pass
        raise
    return destination


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("path", type=Path)
    parser.add_argument("--expect-name")
    parser.add_argument("--expect-type")
    parser.add_argument("--expect-creator")
    parser.add_argument(
        "--install-to", type=Path,
        help="decode into a native macOS directory, preserving both forks and FinderInfo")
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
        installed = install_native(args.path, args.install_to) \
            if args.install_to is not None else None
    except (OSError, UnicodeError, ValueError) as error:
        print(f"macbinary-identity: {args.path}: {error}", file=sys.stderr)
        return 1

    for key in ("name", "type", "creator", "data", "resource", "bytes", "crc"):
        print(f"{key}={identity[key]}")
    if installed is not None:
        print(f"installed={installed}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
