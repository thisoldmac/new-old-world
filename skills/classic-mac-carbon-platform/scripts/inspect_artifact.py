#!/usr/bin/env python3
"""Inspect classic Mac application artifacts without modifying them."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any


SHARED_SCRIPTS = Path(__file__).resolve().parents[3] / "scripts"
sys.path.insert(0, str(SHARED_SCRIPTS))

from classic_mac_formats import ParseError, parse_macbinary, parse_resource_fork  # noqa: E402


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def xattr(path: Path, name: str) -> bytes | None:
    if hasattr(os, "getxattr"):
        try:
            return os.getxattr(path, name)
        except OSError:
            pass
    tool = Path("/usr/bin/xattr")
    if tool.exists():
        result = subprocess.run(
            [str(tool), "-px", name, str(path)],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode == 0:
            try:
                return bytes.fromhex("".join(result.stdout.split()))
            except ValueError:
                return None
    return None


def run(argv: list[str]) -> dict[str, Any]:
    try:
        result = subprocess.run(argv, text=True, capture_output=True, check=False)
    except OSError as exc:
        return {"argv": argv, "error": str(exc)}
    return {
        "argv": argv,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def classify(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix == ".xcoff":
        return "xcoff"
    if suffix == ".pef":
        return "pef-data-fork"
    if suffix == ".bin":
        return "macbinary"
    if suffix == ".dsk":
        return "hfs-disk-image"
    if suffix == ".ad" or path.name.startswith("%"):
        return "appledouble-member"
    if suffix == ".appl":
        return "native-appl"
    return "unknown"


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("artifact", type=Path)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    path = args.artifact.resolve()
    if not path.is_file():
        parser.error(f"artifact is not a file: {path}")
    bin_dir = args.toolchain.resolve() / "bin"
    kind = classify(path)
    finder = xattr(path, "com.apple.FinderInfo")
    resource = xattr(path, "com.apple.ResourceFork")
    data: dict[str, Any] = {
        "schema": "classic-mac-artifact-inspection-v1",
        "path": str(path),
        "kind": kind,
        "size": path.stat().st_size,
        "data_sha256": sha256_file(path),
        "finder_info": finder.hex() if finder is not None else None,
        "resource_fork_size": len(resource) if resource is not None else None,
        "resource_fork_sha256": sha256_bytes(resource) if resource is not None else None,
        "warnings": [],
    }

    resinfo = bin_dir / "ResInfo"
    if resinfo.exists() and kind in {"native-appl", "macbinary", "unknown"}:
        result = run([str(resinfo), "-a", str(path)])
        data["resinfo"] = result
        if result.get("returncode") != 0:
            data["warnings"].append("ResInfo could not parse this artifact")

    if kind == "xcoff":
        objdump = bin_dir / "powerpc-apple-macos-objdump"
        result = run([str(objdump), "-h", str(path)])
        data["sections"] = result
        output = result.get("stdout", "")
        data["has_dwarf"] = any(
            section in output for section in (".dwinfo", ".dwline", ".debug_info")
        )
        if not data["has_dwarf"]:
            data["warnings"].append("XCOFF has no recognized DWARF sections")

    if kind == "pef-data-fork":
        data["warnings"].append(
            "PEF is a data-fork intermediate, not a complete classic application"
        )

    if kind == "macbinary":
        try:
            container = parse_macbinary(path.read_bytes())
            macbinary: dict[str, Any] = {
                "parsing_status": "parsed",
                **container.metadata,
                "data_fork_sha256": sha256_bytes(container.data_fork),
                "resource_fork_sha256": sha256_bytes(container.resource_fork)
                if container.resource_fork
                else None,
                "resources": [],
            }
            if container.resource_fork:
                try:
                    macbinary["resources"] = [
                        {
                            "type": resource.type,
                            "id": resource.id,
                            "attributes": resource.attributes,
                            "size": resource.size,
                        }
                        for resource in parse_resource_fork(container.resource_fork)
                    ]
                except ParseError as error:
                    macbinary["parsing_status"] = "metadata-only"
                    macbinary["resource_parse_error"] = str(error)
                    data["warnings"].append("MacBinary resource fork could not be inventoried")
            else:
                macbinary["parsing_status"] = "no-resource-fork"
                data["warnings"].append("MacBinary contains no resource-fork evidence")
            data["macbinary"] = macbinary
        except ParseError as error:
            data["macbinary"] = {"parsing_status": "invalid", "error": str(error)}
            data["warnings"].append("MacBinary header or fork layout is invalid")

    if kind == "native-appl" and (finder is None or resource is None):
        data["warnings"].append(
            "native APPL is missing FinderInfo or resource-fork xattr"
        )

    if kind == "appledouble-member":
        if path.name.startswith("%"):
            mate = path.with_name(path.name[1:])
        else:
            mate = path.with_name("%" + path.name)
        data["appledouble_mate"] = str(mate)
        data["appledouble_mate_present"] = mate.is_file()
        if not mate.is_file():
            data["warnings"].append("AppleDouble pair is incomplete")

    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print(f"{path}: {kind}")
        print(f"  data: {data['size']} bytes {data['data_sha256']}")
        print(
            "  resource fork: "
            + (
                f"{data['resource_fork_size']} bytes {data['resource_fork_sha256']}"
                if resource is not None
                else "not represented as native xattr"
            )
        )
        if "resinfo" in data and data["resinfo"].get("stdout"):
            print(f"  ResInfo: {data['resinfo']['stdout']}")
        if kind == "macbinary":
            macbinary = data.get("macbinary", {})
            print(f"  MacBinary parse: {macbinary.get('parsing_status', 'not-run')}")
            if macbinary.get("finder_type"):
                print(
                    f"  Finder identity: {macbinary['finder_type']} / "
                    f"{macbinary.get('finder_creator', '????')}"
                )
            print(f"  resource inventory: {len(macbinary.get('resources', []))} entries")
        if kind == "xcoff":
            print(f"  DWARF: {'present' if data['has_dwarf'] else 'not detected'}")
        for warning in data["warnings"]:
            print(f"  warning: {warning}")
    return 1 if data["warnings"] and kind in {"native-appl", "macbinary"} else 0


if __name__ == "__main__":
    raise SystemExit(main())
