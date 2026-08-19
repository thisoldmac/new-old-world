#!/usr/bin/env python3
"""Fingerprint a Retro68 PowerPC Carbon toolchain and optional CMake build."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
from pathlib import Path
from typing import Any


def run(argv: list[str], cwd: Path | None = None) -> dict[str, Any]:
    try:
        result = subprocess.run(
            argv, cwd=cwd, text=True, capture_output=True, check=False
        )
    except OSError as exc:
        return {"argv": argv, "error": str(exc)}
    return {
        "argv": argv,
        "returncode": result.returncode,
        "stdout": result.stdout.strip(),
        "stderr": result.stderr.strip(),
    }


def sha256(path: Path) -> str | None:
    if not path.is_file():
        return None
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def git_fingerprint(source: Path) -> dict[str, Any]:
    if not (source / ".git").exists():
        return {"path": str(source), "error": "not a git worktree"}
    commit = run(["git", "rev-parse", "HEAD"], source)
    status = run(["git", "status", "--porcelain"], source)
    branch = run(["git", "branch", "--show-current"], source)
    return {
        "path": str(source.resolve()),
        "commit": commit.get("stdout") if commit.get("returncode") == 0 else None,
        "branch": branch.get("stdout") if branch.get("returncode") == 0 else None,
        "dirty": bool(status.get("stdout")) if status.get("returncode") == 0 else None,
        "errors": [
            item.get("stderr") or item.get("error")
            for item in (commit, status, branch)
            if item.get("returncode", 1) != 0
        ],
    }


def compiler_fingerprint(path: Path) -> dict[str, Any]:
    result = run([str(path), "--version"])
    return {
        "path": str(path),
        "resolved_path": str(path.resolve()) if path.exists() else None,
        "version": (result.get("stdout") or "").splitlines()[0] or None,
        "error": result.get("error") or (
            result.get("stderr") if result.get("returncode", 1) != 0 else None
        ),
    }


def universal_interfaces_version(header: Path) -> str | None:
    if not header.is_file():
        return None
    text = header.read_text(encoding="mac_roman", errors="replace")
    patterns = (
        r"#define\s+UNIVERSAL_INTERFACES_VERSION\s+(0x[0-9A-Fa-f]+)",
        r"#define\s+UNIVERSAL_INTERFACES_VERSION\s+([0-9]+)",
    )
    for pattern in patterns:
        match = re.search(pattern, text)
        if match:
            return match.group(1)
    return None


def cmake_cache(path: Path | None) -> dict[str, str]:
    if path is None:
        return {}
    cache = path / "CMakeCache.txt" if path.is_dir() else path
    if not cache.is_file():
        return {"error": f"CMake cache not found: {cache}"}
    wanted = re.compile(
        r"^(CMAKE_(?:C|CXX)_COMPILER|CMAKE_TOOLCHAIN_FILE|CMAKE_BUILD_TYPE|"
        r"CMAKE_(?:C|CXX)_FLAGS(?:_[A-Z]+)?|RETRO68_[A-Z0-9_]+):[^=]*=(.*)$"
    )
    values: dict[str, str] = {}
    for line in cache.read_text(encoding="utf-8", errors="replace").splitlines():
        match = wanted.match(line)
        if match:
            values[match.group(1)] = match.group(2)
    values["cache_path"] = str(cache.resolve())
    return values


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--retro68-source", type=Path, required=True)
    parser.add_argument("--toolchain", type=Path, required=True)
    parser.add_argument("--build", type=Path, help="CMake build directory or cache")
    parser.add_argument("--json", action="store_true", help="Emit JSON only")
    args = parser.parse_args()

    toolchain = args.toolchain.resolve()
    bin_dir = toolchain / "bin"
    ui_header = toolchain / "universal" / "CIncludes" / "ConditionalMacros.h"
    carbon_archive = toolchain / "universal" / "libppc" / "libCarbonLib.a"
    tools = [
        "Rez",
        "MakePEF",
        "MakeImport",
        "ResInfo",
        "LaunchAPPL",
        "powerpc-apple-macos-nm",
        "powerpc-apple-macos-objdump",
    ]

    data: dict[str, Any] = {
        "schema": "classic-mac-carbon-toolchain-fingerprint-v1",
        "retro68": git_fingerprint(args.retro68_source.resolve()),
        "toolchain": str(toolchain),
        "target_triplet": "powerpc-apple-macos",
        "compilers": {
            "c": compiler_fingerprint(bin_dir / "powerpc-apple-macos-gcc"),
            "cxx": compiler_fingerprint(bin_dir / "powerpc-apple-macos-g++"),
        },
        "universal_interfaces": {
            "header": str(ui_header),
            "version": universal_interfaces_version(ui_header),
        },
        "carbon_import_archive": {
            "path": str(carbon_archive),
            "resolved_path": str(carbon_archive.resolve()) if carbon_archive.exists() else None,
            "sha256": sha256(carbon_archive.resolve()) if carbon_archive.exists() else None,
        },
        "tools": {
            name: {
                "path": str(bin_dir / name),
                "present": (bin_dir / name).exists(),
                "resolved_path": str((bin_dir / name).resolve())
                if (bin_dir / name).exists()
                else None,
            }
            for name in tools
        },
        "cmake": cmake_cache(args.build),
    }

    if args.json:
        print(json.dumps(data, indent=2, sort_keys=True))
        return 0

    print(f"Retro68: {data['retro68'].get('commit') or 'unknown'}")
    print(f"  source: {data['retro68']['path']}")
    print(f"  dirty: {data['retro68'].get('dirty')}")
    print(f"Toolchain: {toolchain}")
    print(f"  C: {data['compilers']['c']['version'] or 'unavailable'}")
    print(f"  C++: {data['compilers']['cxx']['version'] or 'unavailable'}")
    print(
        "  Universal Interfaces: "
        f"{data['universal_interfaces']['version'] or 'unavailable'}"
    )
    print(
        "  libCarbonLib.a SHA-256: "
        f"{data['carbon_import_archive']['sha256'] or 'unavailable'}"
    )
    missing = [name for name, item in data["tools"].items() if not item["present"]]
    print(f"  missing tools: {', '.join(missing) if missing else 'none'}")
    if data["cmake"]:
        print(f"CMake facts: {len(data['cmake'])} field(s)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
