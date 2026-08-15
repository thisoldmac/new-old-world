from __future__ import annotations

import json
import os
from datetime import datetime, timezone
from pathlib import Path

from .artifacts import sha256
from .profile import ReleaseRefusal


def source_date() -> str:
    raw = os.environ.get("SOURCE_DATE_EPOCH")
    if raw is None:
        raise ReleaseRefusal("SOURCE_DATE_EPOCH is required for recorded releases")
    try:
        return datetime.fromtimestamp(int(raw), timezone.utc).isoformat().replace(
            "+00:00", "Z")
    except (ValueError, OSError, OverflowError) as exc:
        raise ReleaseRefusal(f"invalid SOURCE_DATE_EPOCH: {exc}")


def write_manifest(path: Path, *, version: str, channel: str,
                   source_revision: str, components: list[dict],
                   licensed_inputs: list[dict], outputs: list[Path]) -> None:
    rows = [
        {
            "filename": output.name,
            "bytes": output.stat().st_size,
            "sha256": sha256(output),
        }
        for output in sorted(outputs, key=lambda item: item.name)
    ]
    document = {
        "schema": 1,
        "profile": "alpha-distribution",
        "productVersion": version,
        "channel": channel,
        "sourceRevision": source_revision,
        "sourceDate": source_date(),
        "components": components,
        "licensedInputs": licensed_inputs,
        "outputs": rows,
    }
    path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n")


def write_checksums(path: Path, outputs: list[Path]) -> None:
    lines = [f"{sha256(output)}  {output.name}" for output in sorted(
        outputs, key=lambda item: item.name)]
    path.write_text("\n".join(lines) + "\n")
