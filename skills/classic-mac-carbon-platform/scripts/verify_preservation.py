#!/usr/bin/env python3
"""Compare data, FinderInfo, and resource-fork preservation end to end."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
from pathlib import Path
from typing import Any


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


def snapshot(path: Path) -> dict[str, Any]:
    finder = xattr(path, "com.apple.FinderInfo")
    resource = xattr(path, "com.apple.ResourceFork")
    return {
        "path": str(path.resolve()),
        "size": path.stat().st_size,
        "data_sha256": sha256_file(path),
        "finder_info": finder.hex() if finder is not None else None,
        "resource_fork_size": len(resource) if resource is not None else None,
        "resource_fork_sha256": hashlib.sha256(resource).hexdigest()
        if resource is not None
        else None,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("reconstructed", type=Path)
    parser.add_argument(
        "--require-classic-metadata",
        action="store_true",
        help="Fail if the source lacks FinderInfo or a resource fork",
    )
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    for path in (args.source, args.reconstructed):
        if not path.is_file():
            parser.error(f"not a file: {path}")

    source = snapshot(args.source)
    reconstructed = snapshot(args.reconstructed)
    fields = (
        "size",
        "data_sha256",
        "finder_info",
        "resource_fork_size",
        "resource_fork_sha256",
    )
    comparison = {
        field: {
            "source": source[field],
            "reconstructed": reconstructed[field],
            "equal": source[field] == reconstructed[field],
        }
        for field in fields
    }
    failures = [field for field, item in comparison.items() if not item["equal"]]
    if args.require_classic_metadata:
        if source["finder_info"] is None:
            failures.append("source FinderInfo missing")
        if source["resource_fork_sha256"] is None:
            failures.append("source resource fork missing")
    data = {
        "schema": "classic-mac-preservation-comparison-v1",
        "source": source,
        "reconstructed": reconstructed,
        "comparison": comparison,
        "passed": not failures,
        "failures": failures,
    }

    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
    else:
        print(f"preservation: {'PASS' if data['passed'] else 'FAIL'}")
        for field, item in comparison.items():
            print(f"  {field}: {'equal' if item['equal'] else 'DIFFERS'}")
        for failure in failures:
            if failure not in comparison:
                print(f"  failure: {failure}")
    return 0 if data["passed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
