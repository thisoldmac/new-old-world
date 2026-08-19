#!/usr/bin/env python3
"""Inspect a classic Mac APPL in MacBinary or raw resource-fork form."""

from __future__ import annotations

import argparse
import hashlib
import json
import struct
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


class ParseError(ValueError):
    pass


@dataclass
class Resource:
    type: str
    id: int
    attributes: int
    size: int


def u16(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 2 > len(data):
        raise ParseError(f"16-bit read outside file at {offset}")
    return struct.unpack_from(">H", data, offset)[0]


def s16(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 2 > len(data):
        raise ParseError(f"signed 16-bit read outside file at {offset}")
    return struct.unpack_from(">h", data, offset)[0]


def u32(data: bytes, offset: int) -> int:
    if offset < 0 or offset + 4 > len(data):
        raise ParseError(f"32-bit read outside file at {offset}")
    return struct.unpack_from(">I", data, offset)[0]


def ostype(data: bytes) -> str:
    return data.decode("mac_roman", errors="replace")


def sha256(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def extract_forks(blob: bytes) -> tuple[str, dict[str, object], bytes, bytes]:
    if len(blob) >= 128 and blob[0] == 0 and 1 <= blob[1] <= 63:
        data_size = u32(blob, 83)
        resource_size = u32(blob, 87)
        data_start = 128
        data_end = data_start + data_size
        resource_start = 128 + ((data_size + 127) // 128) * 128
        resource_end = resource_start + resource_size
        if resource_size and data_end <= len(blob) and resource_end <= len(blob):
            metadata = {
                "filename": ostype(blob[2 : 2 + blob[1]]),
                "finder_type": ostype(blob[65:69]),
                "finder_creator": ostype(blob[69:73]),
                "data_fork_size": data_size,
                "resource_fork_size": resource_size,
            }
            return (
                "macbinary",
                metadata,
                blob[data_start:data_end],
                blob[resource_start:resource_end],
            )

    if len(blob) < 16:
        raise ParseError("file is neither valid MacBinary nor a resource fork")
    data_offset = u32(blob, 0)
    map_offset = u32(blob, 4)
    data_size = u32(blob, 8)
    map_size = u32(blob, 12)
    if (
        data_offset < 16
        or map_offset < 16
        or data_offset + data_size > len(blob)
        or map_offset + map_size > len(blob)
    ):
        raise ParseError("resource-fork header points outside file")
    return "resource-fork", {"resource_fork_size": len(blob)}, b"", blob


def parse_resources(fork: bytes) -> list[Resource]:
    if len(fork) < 16:
        raise ParseError("resource fork is shorter than its header")
    data_offset = u32(fork, 0)
    map_offset = u32(fork, 4)
    data_size = u32(fork, 8)
    map_size = u32(fork, 12)
    if data_offset + data_size > len(fork) or map_offset + map_size > len(fork):
        raise ParseError("resource data or map lies outside resource fork")

    resource_map = fork[map_offset : map_offset + map_size]
    if len(resource_map) < 28:
        raise ParseError("resource map is shorter than its header")
    type_list_offset = u16(resource_map, 24)
    type_count = u16(resource_map, type_list_offset) + 1
    if type_list_offset + 2 + type_count * 8 > len(resource_map):
        raise ParseError("type entries lie outside resource map")

    result: list[Resource] = []
    for type_index in range(type_count):
        entry = type_list_offset + 2 + type_index * 8
        resource_type = ostype(resource_map[entry : entry + 4])
        resource_count = u16(resource_map, entry + 4) + 1
        reference_base = type_list_offset + u16(resource_map, entry + 6)
        if reference_base + resource_count * 12 > len(resource_map):
            raise ParseError(f"reference list for {resource_type!r} is invalid")
        for resource_index in range(resource_count):
            reference = reference_base + resource_index * 12
            attributes_and_offset = u32(resource_map, reference + 4)
            record = data_offset + (attributes_and_offset & 0x00FFFFFF)
            payload_size = u32(fork, record)
            if record + 4 + payload_size > data_offset + data_size:
                raise ParseError(
                    f"payload for {resource_type} lies outside resource data"
                )
            result.append(
                Resource(
                    type=resource_type,
                    id=s16(resource_map, reference),
                    attributes=attributes_and_offset >> 24,
                    size=payload_size,
                )
            )
    return result


def inspect(path: Path) -> dict[str, object]:
    blob = path.read_bytes()
    file_format, metadata, data_fork, resource_fork = extract_forks(blob)
    resources = parse_resources(resource_fork)
    errors: list[str] = []
    warnings: list[str] = []

    if file_format == "macbinary":
        if metadata.get("finder_type") != "APPL":
            errors.append(
                f"Finder type is {metadata.get('finder_type')!r}, expected 'APPL'"
            )
        if metadata.get("finder_creator") == "????":
            warnings.append("Finder creator is still the template value '????'")
    else:
        warnings.append("raw resource fork has no Finder type or creator evidence")

    resource_types = {resource.type for resource in resources}
    has_68k = "CODE" in resource_types
    has_ppc = "cfrg" in resource_types and bool(data_fork)
    if "SIZE" not in resource_types:
        warnings.append("missing SIZE resource")
    if not has_68k and not has_ppc:
        errors.append("no classic 68K CODE or PPC data-fork/cfrg application found")

    profile = (
        "fat-classic-68k-ppc"
        if has_68k and has_ppc
        else "classic-68k"
        if has_68k
        else "native-ppc-cfm"
    )
    return {
        "path": str(path),
        "format": file_format,
        "profile": profile,
        "metadata": metadata,
        "data_fork_sha256": sha256(data_fork) if data_fork else None,
        "resource_fork_sha256": sha256(resource_fork),
        "resources": [asdict(resource) for resource in resources],
        "errors": errors,
        "warnings": warnings,
        "ok": not errors,
    }


def print_text(report: dict[str, object]) -> None:
    print(f"format: {report['format']}")
    print(f"profile: {report['profile']}")
    metadata = report["metadata"]
    assert isinstance(metadata, dict)
    for key, value in metadata.items():
        print(f"{key}: {value}")
    print("resources:")
    for raw_resource in report["resources"]:
        assert isinstance(raw_resource, dict)
        print(
            f"  {raw_resource['type']} {raw_resource['id']} "
            f"attrs=0x{raw_resource['attributes']:02x} size={raw_resource['size']}"
        )
    for warning in report["warnings"]:
        print(f"warning: {warning}", file=sys.stderr)
    for error in report["errors"]:
        print(f"error: {error}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()
    try:
        report = inspect(args.artifact)
    except (OSError, ParseError) as error:
        if args.json:
            print(json.dumps({"path": str(args.artifact), "ok": False, "errors": [str(error)]}))
        else:
            print(f"error: {error}", file=sys.stderr)
        return 2
    if args.json:
        print(json.dumps(report, indent=2, sort_keys=True))
    else:
        print_text(report)
    return 0 if report["ok"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
