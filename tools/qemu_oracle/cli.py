"""Command line for coherent QEMU memory snapshots and offline diffs."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import tempfile

from .classic import build_snapshot
from .qmp import (OracleError, QMPClient, VirtualMemory, coherent_context,
                  read_identity)


SCHEMA = "now-qemu-memory-oracle/v1"


def _now() -> str:
    return datetime.now(timezone.utc).isoformat().replace("+00:00", "Z")


def capture(qmp_path: str, identity_path: str, app: str,
            attempts: int, interval: float) -> dict:
    identity = read_identity(identity_path, qmp_path)
    qmp = QMPClient(qmp_path)
    try:
        actual_name = qmp.execute("query-name").get("name")
        if actual_name != identity["vmName"]:
            raise OracleError(
                f"QMP VM identity mismatch: expected {identity['vmName']!r}, "
                f"got {actual_name!r}")
        with tempfile.TemporaryDirectory(prefix="now-qemu-oracle-") as root:
            memory = VirtualMemory(qmp, Path(root))
            with coherent_context(qmp, memory, app, attempts, interval) as match:
                state = build_snapshot(memory, app)
        return {
            "schema": SCHEMA,
            "capturedAt": _now(),
            "source": "qmp-virtual-memory",
            "guest": identity["guest"],
            "session": identity["session"],
            "build": identity["build"],
            "vmName": identity["vmName"],
            "qmpSocket": os.path.realpath(qmp_path),
            "contextAttempt": match["attempt"],
            "state": state,
        }
    finally:
        qmp.close()


def diff_values(before, after, path: str = "", limit: int = 512) -> list:
    changes = []

    def visit(left, right, at):
        if len(changes) >= limit or left == right:
            return
        if isinstance(left, dict) and isinstance(right, dict):
            for key in sorted(set(left) | set(right)):
                child = f"{at}.{key}" if at else key
                if key not in left:
                    changes.append({"path": child, "before": None,
                                    "after": right[key]})
                elif key not in right:
                    changes.append({"path": child, "before": left[key],
                                    "after": None})
                else:
                    visit(left[key], right[key], child)
                if len(changes) >= limit:
                    return
        elif isinstance(left, list) and isinstance(right, list):
            for index in range(max(len(left), len(right))):
                child = f"{at}[{index}]"
                if index >= len(left):
                    changes.append({"path": child, "before": None,
                                    "after": right[index]})
                elif index >= len(right):
                    changes.append({"path": child, "before": left[index],
                                    "after": None})
                else:
                    visit(left[index], right[index], child)
                if len(changes) >= limit:
                    return
        else:
            changes.append({"path": at, "before": left, "after": right})

    visit(before, after, path)
    return changes


def _read_snapshot(path: str):
    try:
        value = json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError) as exc:
        raise OracleError(f"cannot read snapshot {path}: {exc}")
    if value.get("schema") != SCHEMA:
        raise OracleError(f"snapshot {path} has the wrong schema")
    return value


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(
        description="QEMU-only classic Mac memory development oracle")
    sub = parser.add_subparsers(dest="command", required=True)
    snapshot = sub.add_parser("snapshot")
    snapshot.add_argument("--qmp", required=True)
    snapshot.add_argument("--identity", required=True)
    snapshot.add_argument("--app", required=True,
                          help="CurApName context that must be sampled")
    snapshot.add_argument("--out", help="write JSON here (default stdout)")
    snapshot.add_argument("--attempts", type=int, default=80)
    snapshot.add_argument("--interval", type=float, default=0.05)

    compare = sub.add_parser("diff")
    compare.add_argument("before")
    compare.add_argument("after")
    compare.add_argument("--out", help="write JSON here (default stdout)")

    args = parser.parse_args(argv)
    try:
        if args.command == "snapshot":
            value = capture(args.qmp, args.identity, args.app,
                            args.attempts, args.interval)
        else:
            before = _read_snapshot(args.before)
            after = _read_snapshot(args.after)
            value = {
                "schema": "now-qemu-memory-oracle-diff/v1",
                "before": str(Path(args.before).resolve()),
                "after": str(Path(args.after).resolve()),
                "changes": diff_values(before["state"], after["state"]),
            }
        encoded = json.dumps(value, indent=2, sort_keys=True) + "\n"
        if args.out:
            Path(args.out).write_text(encoded, encoding="utf-8")
            print(str(Path(args.out).resolve()))
        else:
            print(encoded, end="")
        return 0
    except OracleError as exc:
        parser.error(str(exc))
        return 2
