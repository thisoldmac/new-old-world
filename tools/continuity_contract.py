"""Read the Continuity constants owned by the shared C contract headers."""

from __future__ import annotations

import re
from pathlib import Path


def _number(path: Path, name: str) -> int:
    match = re.search(
        rf"^\s*#define\s+{re.escape(name)}\s+"
        r"(0[xX][0-9a-fA-F]+|[0-9]+)[uUlL]*\s*$",
        path.read_text(), re.MULTILINE)
    if not match:
        raise RuntimeError(f"{path}: no numeric {name} definition")
    return int(match.group(1), 0)


def values(repo_root: Path) -> dict[str, int | str]:
    contract = repo_root / "contract"
    major = _number(contract / "resident_version.h",
                    "NOW_RESIDENT_VERSION_MAJOR")
    minor = _number(contract / "resident_version.h",
                    "NOW_RESIDENT_VERSION_MINOR")
    return {
        "continuityWire": _number(contract / "continuity_udp.h",
                                  "NOW_CONTINUITY_VERSION"),
        "continuityTable": _number(contract / "peek_table.h",
                                   "NOW_CONTINUITY_FORMAT_CURRENT"),
        "resident": f"{major}.{minor}",
    }
