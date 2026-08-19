#!/usr/bin/env python3
"""Symbolicate a C9CR v1 crash record against its exact Retro68 XCOFF."""

from __future__ import annotations

import argparse
import bisect
import hashlib
import json
import re
import struct
import subprocess
from pathlib import Path
from typing import Any


MAGIC = b"C9CR"
VERSION = 1
RECORD_SIZE = 160
HEADER = struct.Struct(">4sHHII32s9IHH8s")
FRAME = struct.Struct(">II")


def sha256_file(path: Path) -> bytes:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.digest()


def run(argv: list[str]) -> str:
    result = subprocess.run(argv, text=True, capture_output=True, check=False)
    if result.returncode != 0:
        detail = result.stderr.strip() or result.stdout.strip()
        raise RuntimeError(f"command failed ({result.returncode}): {' '.join(argv)}: {detail}")
    return result.stdout


def parse_record(path: Path) -> dict[str, Any]:
    raw = path.read_bytes()
    if len(raw) != RECORD_SIZE:
        raise ValueError(f"expected {RECORD_SIZE} bytes, found {len(raw)}")
    values = HEADER.unpack_from(raw)
    (
        magic,
        version,
        record_size,
        flags,
        exception_kind,
        build_sha256,
        runtime_anchor,
        pc,
        lr,
        sp,
        fault_address,
        ctr,
        cr,
        xer,
        msr,
        frame_count,
        frame_capacity,
        reserved,
    ) = values
    if magic != MAGIC:
        raise ValueError(f"bad magic: {magic!r}")
    if version != VERSION:
        raise ValueError(f"unsupported version: {version}")
    if record_size != RECORD_SIZE:
        raise ValueError(f"record declares size {record_size}, expected {RECORD_SIZE}")
    if frame_capacity != 8 or frame_count > frame_capacity:
        raise ValueError(
            f"invalid frame count/capacity: {frame_count}/{frame_capacity}"
        )
    if reserved != b"\x00" * 8:
        raise ValueError("reserved bytes are nonzero")
    frames = [
        dict(zip(("sp", "saved_lr"), FRAME.unpack_from(raw, 96 + index * 8)))
        for index in range(frame_count)
    ]
    return {
        "flags": flags,
        "exception_kind": exception_kind,
        "build_sha256": build_sha256,
        "runtime_anchor": runtime_anchor,
        "pc": pc,
        "lr": lr,
        "sp": sp,
        "fault_address": fault_address,
        "ctr": ctr,
        "cr": cr,
        "xer": xer,
        "msr": msr,
        "frames": frames,
    }


def parse_symbols(text: str) -> list[tuple[int, str]]:
    symbols: list[tuple[int, str]] = []
    pattern = re.compile(r"^\s*([0-9A-Fa-f]+)\s+([A-Za-z?])\s+(.+?)\s*$")
    for line in text.splitlines():
        match = pattern.match(line)
        if match and match.group(2) in {"T", "t", "W", "w"}:
            symbols.append((int(match.group(1), 16), match.group(3)))
    return sorted(symbols)


def parse_lines(text: str) -> list[tuple[int, str, int]]:
    rows: list[tuple[int, str, int]] = []
    pattern = re.compile(r"^\s*(.*?)\s+(\d+)\s+0x([0-9A-Fa-f]+)(?:\s|$)")
    for line in text.splitlines():
        match = pattern.match(line)
        if match and match.group(1) != "File name":
            rows.append((int(match.group(3), 16), match.group(1), int(match.group(2))))
    return sorted(rows)


def find_anchor(symbols: list[tuple[int, str]], name: str) -> int:
    matches = [address for address, symbol in symbols if symbol == name]
    if not matches:
        raise ValueError(f"anchor instruction symbol not found: {name}")
    if len(set(matches)) != 1:
        raise ValueError(f"anchor instruction symbol is ambiguous: {name}")
    return matches[0]


def nearest_symbol(symbols: list[tuple[int, str]], address: int) -> dict[str, Any] | None:
    addresses = [item[0] for item in symbols]
    index = bisect.bisect_right(addresses, address) - 1
    if index < 0:
        return None
    base, name = symbols[index]
    return {"name": name, "base": base, "offset": address - base}


def nearest_line(lines: list[tuple[int, str, int]], address: int) -> dict[str, Any] | None:
    addresses = [item[0] for item in lines]
    index = bisect.bisect_right(addresses, address) - 1
    if index < 0:
        return None
    base, filename, line = lines[index]
    return {"file": filename, "line": line, "base": base, "offset": address - base}


def translate(
    runtime_address: int,
    runtime_anchor: int,
    link_anchor: int,
    symbols: list[tuple[int, str]],
    lines: list[tuple[int, str, int]],
) -> dict[str, Any]:
    link_address = link_anchor + (runtime_address - runtime_anchor)
    valid = 0 <= link_address <= 0xFFFFFFFF
    return {
        "runtime": runtime_address,
        "link": link_address if valid else None,
        "valid": valid,
        "symbol": nearest_symbol(symbols, link_address) if valid else None,
        "source": nearest_line(lines, link_address) if valid else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("record", type=Path)
    parser.add_argument("xcoff", type=Path)
    parser.add_argument("--toolchain", type=Path, required=True)
    anchor = parser.add_mutually_exclusive_group(required=True)
    anchor.add_argument("--anchor-symbol", help="XCOFF instruction symbol, often .name")
    anchor.add_argument(
        "--anchor-link-address",
        type=lambda value: int(value, 0),
        help="Known link-time instruction address",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    record = parse_record(args.record)
    actual_hash = sha256_file(args.xcoff)
    if actual_hash != record["build_sha256"]:
        raise SystemExit(
            "XCOFF SHA-256 does not match crash record: "
            f"record={record['build_sha256'].hex()} actual={actual_hash.hex()}"
        )
    if record["runtime_anchor"] == 0:
        raise SystemExit("crash record has a zero runtime anchor")

    bin_dir = args.toolchain.resolve() / "bin"
    nm_text = run(
        [str(bin_dir / "powerpc-apple-macos-nm"), "-n", str(args.xcoff)]
    )
    lines_text = run(
        [
            str(bin_dir / "powerpc-apple-macos-objdump"),
            "--dwarf=decodedline",
            str(args.xcoff),
        ]
    )
    symbols = parse_symbols(nm_text)
    lines = parse_lines(lines_text)
    link_anchor = (
        args.anchor_link_address
        if args.anchor_link_address is not None
        else find_anchor(symbols, args.anchor_symbol)
    )

    addresses = {
        name: translate(
            record[name], record["runtime_anchor"], link_anchor, symbols, lines
        )
        for name in ("pc", "lr", "ctr")
        if record[name] != 0
    }
    frames = [
        {
            "sp": frame["sp"],
            "saved_lr": translate(
                frame["saved_lr"],
                record["runtime_anchor"],
                link_anchor,
                symbols,
                lines,
            )
            if frame["saved_lr"]
            else None,
        }
        for frame in record["frames"]
    ]
    output = {
        "schema": "classic-mac-symbolication-v1",
        "record": str(args.record.resolve()),
        "xcoff": str(args.xcoff.resolve()),
        "xcoff_sha256": actual_hash.hex(),
        "exception_kind": record["exception_kind"],
        "runtime_anchor": record["runtime_anchor"],
        "link_anchor": link_anchor,
        "anchor_symbol": args.anchor_symbol,
        "registers": {
            key: record[key]
            for key in ("sp", "fault_address", "cr", "xer", "msr", "flags")
        },
        "addresses": addresses,
        "frames": frames,
        "notes": [
            "frames are best effort; leaf routines, tail calls, optimized prologs, and corruption can create gaps"
        ],
    }

    if args.json:
        print(json.dumps(output, indent=2, sort_keys=True))
    else:
        print(f"XCOFF: {args.xcoff} ({actual_hash.hex()})")
        print(
            f"anchor: runtime=0x{record['runtime_anchor']:08x} "
            f"link=0x{link_anchor:08x}"
        )
        for name, item in addresses.items():
            if not item["valid"]:
                print(f"{name}: runtime=0x{item['runtime']:08x} invalid translation")
                continue
            symbol = item["symbol"]
            source = item["source"]
            symbol_text = (
                f"{symbol['name']}+0x{symbol['offset']:x}" if symbol else "?"
            )
            source_text = (
                f"{source['file']}:{source['line']}+0x{source['offset']:x}"
                if source
                else "?:?"
            )
            print(
                f"{name}: runtime=0x{item['runtime']:08x} "
                f"link=0x{item['link']:08x} {symbol_text} {source_text}"
            )
        for index, frame in enumerate(frames):
            saved = frame["saved_lr"]
            if saved and saved["valid"]:
                symbol = saved["symbol"]
                symbol_text = (
                    f"{symbol['name']}+0x{symbol['offset']:x}" if symbol else "?"
                )
                print(
                    f"frame {index}: sp=0x{frame['sp']:08x} "
                    f"saved-lr=0x{saved['runtime']:08x} {symbol_text}"
                )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
