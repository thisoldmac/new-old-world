#!/usr/bin/env python3
"""Prove one mac99 pointing-device profile before testing Continuity.

QMP supplies hardware stimulus only. NOW's `mouseloc` is the guest-side
observer, and the live CursorData record is found by its structural
fingerprint before its buttonCount byte is trusted. No screen coordinates are
used to aim at UI and no product input plane participates.
"""

import argparse
import importlib.util
import json
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402


def load_hyphenated(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


mechanism = load_hyphenated(
    "cursor_mechanism", os.path.join(ROOT, "tools", "local-cursor-mechanism.py"))
sprite = load_hyphenated(
    "cursor_sprite", os.path.join(ROOT, "tools", "local-cursor-sprite.py"))
Qmp = mechanism.Qmp


def rows(link):
    reply = link.command("mouseloc", timeout=30)
    return dict(reply.get("mouseloc") or [])


def expect_build(link, prefix):
    build = str(link.hello.get("build") or "")
    if prefix and not build.startswith(prefix):
        raise SystemExit(f"wrong guest build: expected prefix {prefix!r}, got {build!r}")
    return build


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--via", required=True, choices=("pmu", "pmu-adb", "cuda"))
    ap.add_argument("--expect-build-prefix", required=True)
    ap.add_argument("--artifacts", required=True)
    args = ap.parse_args()

    # QMP resolves pmemsave filenames in QEMU's working directory, not in the
    # probe process. A relative --artifacts path therefore failed after the
    # physical button went down and before the release event was sent. Make
    # every path handed across that process boundary absolute up front.
    args.artifacts = os.path.abspath(args.artifacts)
    os.makedirs(args.artifacts, exist_ok=True)
    # Listen before occupying the rig's one-shot QMP socket.  This leaves QMP
    # available to launch a guest that is not already running; once the guest
    # dials, this probe takes QMP solely for the hardware stimulus below.
    link = nowwire.GuestLink.await_guest(args.port, timeout=180)
    build = expect_build(link, args.expect_build_prefix)

    q = Qmp(args.qmp)
    qtree = q.hmp("info qtree")
    open(os.path.join(args.artifacts, "qtree.txt"), "w").write(qtree)
    mouse = "usb-mouse" if args.via == "pmu" else "adb-mouse"
    if mouse not in qtree:
        raise SystemExit(f"selected rig has no {mouse} in QEMU qtree")
    controller = "cuda" if "cuda" in qtree.lower() else "pmu"
    if controller != ("cuda" if args.via == "cuda" else "pmu"):
        raise SystemExit(
            f"QEMU topology says {controller}, requested {args.via}; see qtree.txt")

    before_rows = rows(link)
    before = (int(before_rows["x"]), int(before_rows["y"]))

    q.cmd("input-send-event", {"events": [
        {"type": "rel", "data": {"axis": "x", "value": 160}},
        {"type": "rel", "data": {"axis": "y", "value": 120}},
    ]})
    time.sleep(0.8)
    after_rows = rows(link)
    after = (int(after_rows["x"]), int(after_rows["y"]))
    if after == before:
        raise SystemExit(f"{mouse} motion did not reach Mac OS: stayed at {before}")

    # Hold the physical button while locating CursorData. The fingerprint is
    # screenRes=72.0 plus Fixed/integer coordinate agreement; buttonCount is
    # not read until that structural match exists.
    q.cmd("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": True}}
    ]})
    time.sleep(0.35)
    dump = os.path.join(args.artifacts, "button-down-pmem.bin")
    q.pmemsave(dump)
    with open(dump, "rb") as fh:
        blob = fh.read()
    candidates = sprite.find_cursordata(blob)
    down = [(addr, h, v, blob[addr + 21]) for addr, h, v in candidates
            if blob[addr + 21] > 0]
    q.cmd("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": False}}
    ]})
    time.sleep(0.45)
    if not down:
        raise SystemExit("no structurally valid CursorData reported a held button")
    released = []
    for addr, h, v, count in down:
        released.append((addr, h, v, count, q.read_bytes(addr + 21, 1)[0]))
    if not any(item[4] == 0 for item in released):
        raise SystemExit(f"buttonCount did not return to zero: {released}")

    alive_rows = rows(link)
    receipt = {
        "schema": "now-emulator-pointer-control/v1",
        "via": args.via,
        "controller": controller,
        "inputDevice": mouse,
        "adbMouse": mouse == "adb-mouse",
        "guestBuild": build,
        "before": before,
        "after": after,
        "cursorDataButtonTransitions": released,
        "wireAliveAfterInput": "x" in alive_rows and "y" in alive_rows,
    }
    with open(os.path.join(args.artifacts, "pointer-control.json"), "w") as fh:
        json.dump(receipt, fh, indent=2)
    print(json.dumps(receipt, indent=2))
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
