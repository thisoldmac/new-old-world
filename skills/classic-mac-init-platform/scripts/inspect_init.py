#!/usr/bin/env python3
"""Inspect a classic Mac INIT in MacBinary or raw resource-fork form."""

from __future__ import annotations

import argparse
import json
import sys
from dataclasses import asdict, dataclass
from pathlib import Path


SHARED_SCRIPTS = Path(__file__).resolve().parents[3] / "scripts"
sys.path.insert(0, str(SHARED_SCRIPTS))

from classic_mac_formats import (  # noqa: E402
    ParseError,
    extract_resource_fork,
    parse_resource_fork,
)


@dataclass
class Resource:
    type: str
    id: int
    attributes: int
    size: int
    data_hex: str | None = None
    value: int | None = None


def extract_fork(blob: bytes) -> tuple[str, dict[str, object], bytes]:
    return extract_resource_fork(blob)


def parse_resources(fork: bytes) -> list[Resource]:
    return [
        Resource(
            type=entry.type,
            id=entry.id,
            attributes=entry.attributes,
            size=entry.size,
            data_hex=entry.data.hex() if entry.type == "sysz" else None,
            value=int.from_bytes(entry.data, "big")
            if entry.type == "sysz" and entry.size == 4
            else None,
        )
        for entry in parse_resource_fork(fork)
    ]


def inspect(
    path: Path, init_id: int, init_size_budget: int = 32768, enforce_init_size: bool = False
) -> dict[str, object]:
    if init_size_budget <= 0:
        raise ParseError("INIT size budget must be positive")
    blob = path.read_bytes()
    file_format, metadata, fork = extract_fork(blob)
    resources = parse_resources(fork)
    errors: list[str] = []
    warnings: list[str] = []

    if file_format == "macbinary" and metadata.get("finder_type") != "INIT":
        errors.append(f"Finder type is {metadata.get('finder_type')!r}, expected 'INIT'")
    if file_format == "resource-fork":
        warnings.append("raw resource fork has no Finder type or creator evidence")

    init_resources = [r for r in resources if r.type == "INIT" and r.id == init_id]
    if not init_resources:
        errors.append(f"missing INIT resource {init_id}")
    for resource in init_resources:
        if not (resource.attributes & 0x10):
            errors.append(f"INIT {init_id} is not locked")
        if resource.size > init_size_budget:
            message = (
                f"INIT {init_id} is {resource.size} bytes, above the "
                f"{init_size_budget}-byte project budget"
            )
            (errors if enforce_init_size else warnings).append(message)

    sysz_resources = [r for r in resources if r.type == "sysz"]
    for resource in sysz_resources:
        if resource.id != 0:
            warnings.append(f"sysz resource uses ID {resource.id}, expected 0")
        if resource.size != 4 or resource.value is None:
            errors.append(f"sysz {resource.id} must contain one four-byte long word")

    if len(sysz_resources) > 1:
        errors.append("multiple sysz resources found")

    return {
        "path": str(path),
        "format": file_format,
        "metadata": metadata,
        "resources": [asdict(resource) for resource in resources],
        "errors": errors,
        "warnings": warnings,
        "init_size_budget": {
            "bytes": init_size_budget,
            "enforced": enforce_init_size,
        },
        "ok": not errors,
    }


def print_text(report: dict[str, object]) -> None:
    metadata = report["metadata"]
    assert isinstance(metadata, dict)
    print(f"format: {report['format']}")
    for key, value in metadata.items():
        print(f"{key}: {value}")
    print("resources:")
    for raw_resource in report["resources"]:
        assert isinstance(raw_resource, dict)
        suffix = ""
        if raw_resource.get("type") == "sysz" and raw_resource.get("value") is not None:
            suffix = f" bytes-requested={raw_resource['value']}"
        print(
            f"  {raw_resource['type']} {raw_resource['id']} "
            f"attrs=0x{raw_resource['attributes']:02x} size={raw_resource['size']}{suffix}"
        )
    for warning in report["warnings"]:
        print(f"warning: {warning}", file=sys.stderr)
    for error in report["errors"]:
        print(f"error: {error}", file=sys.stderr)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--init-id", type=int, default=128)
    parser.add_argument("--init-size-budget", type=int, default=32768)
    parser.add_argument(
        "--enforce-init-size",
        action="store_true",
        help="treat the configured project size budget as an acceptance limit",
    )
    parser.add_argument(
        "--max-init-size",
        type=int,
        help="deprecated explicit project limit; implies --enforce-init-size",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    try:
        budget = args.max_init_size or args.init_size_budget
        report = inspect(
            args.artifact,
            args.init_id,
            budget,
            args.enforce_init_size or args.max_init_size is not None,
        )
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
