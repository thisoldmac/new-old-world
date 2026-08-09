#!/usr/bin/env python3
"""Drive the mirror the way an AGENT does — over the service socket.

`tests/drive-sequence.py` proves the guest can be driven. This proves the
*agent-facing* surface can drive it: the element-first contract in
`mcp/mirror-service-ipc.toml`, spoken over a unix stream, with no screen
coordinates anywhere in it.

Start the service first:

    MirrorApp --host 127.0.0.1 --port <agent> --machine mac99 --scope front \\
              --qmp <run/qmp.sock> --serve /tmp/mirror.sock

then:

    python3 tests/agent-session.py --socket /tmp/mirror.sock --anchor-port 1700

Note the service becomes the ONE wire client — that is the point of it, and it
is what resolves single-connection contention between agents and a human window.
Do not run a MirrorApp `--window` against the same guest port at the same time.

Framing is uint32 big-endian length + canonical JSON, per the contract.
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import socket
import struct
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
MIRROR = os.path.abspath(os.path.join(HERE, ".."))
LAB = os.path.abspath(os.path.join(MIRROR, ".."))
sys.path.insert(0, os.path.join(LAB, "mcp-classic"))
from timbottu_mcp_classic.harness import Harness  # noqa: E402

FOLDER = "Macintosh HD:Desktop Folder:untitled folder"

steps: list[tuple[str, bool, str]] = []


def step(name: str, ok: bool, detail: str = "") -> bool:
    steps.append((name, ok, detail))
    print(f"  [{'PASS' if ok else 'FAIL'}] {name}" + (f" — {detail}" if detail else ""))
    return ok


class Service:
    """One connection per call; the session id is explicit in params, so this
    is stateless on purpose — an agent process is not required to hold a
    socket open between thoughts."""

    def __init__(self, path: str):
        self.path = path
        self.session: str | None = None

    def raw(self, method: str, params: dict | None = None, timeout: float = 90):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        s.settimeout(timeout)
        s.connect(self.path)
        try:
            body = json.dumps({"id": 1, "method": method,
                               "params": params or {}}).encode()
            s.sendall(struct.pack(">I", len(body)) + body)
            hdr = b""
            while len(hdr) < 4:
                chunk = s.recv(4 - len(hdr))
                if not chunk:
                    raise RuntimeError("service closed the connection")
                hdr += chunk
            n = struct.unpack(">I", hdr)[0]
            buf = b""
            while len(buf) < n:
                chunk = s.recv(n - len(buf))
                if not chunk:
                    break
                buf += chunk
            return json.loads(buf.decode("utf-8", "replace"))
        finally:
            s.close()

    def call(self, method: str, params: dict | None = None):
        p = dict(params or {})
        if self.session:
            p["session"] = self.session
        reply = self.raw(method, p)
        if not reply.get("ok"):
            raise RuntimeError(f"{method}: {reply.get('error')}")
        return reply.get("result", {})


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--socket", required=True)
    ap.add_argument("--anchor-port", type=int, required=True,
                    help="the guest's anchor worker — the actuation oracle")
    ap.add_argument("--shot", default="/tmp/agent-shot.png")
    args = ap.parse_args()

    svc = Service(args.socket)
    h = Harness(host="127.0.0.1", port=args.anchor_port,
                expect_backing={"worker"})

    print("1. attach")
    a = svc.raw("mirror.attach", {"planes": ["semantic", "tracking"]})["result"]
    svc.session = a["session"]
    step("both planes granted", set(a["granted"]) >= {"semantic"},
         f"granted={a['granted']} irVersion={a['irVersion']} "
         f"screen={a['screen']['w']}x{a['screen']['h']}")

    print("\n2. status")
    st = svc.call("mirror.status")
    step("the worker is healthy", bool(st.get("worker", {}).get("healthy")),
         f"pollLatencyMs={st.get('pollLatencyMs')} "
         f"actAvailability={st.get('actAvailability')}")

    print("\n3. perceive — find, element-first")
    counts = {}
    for kind in ("window", "control", "desktopItem", "scrollbar"):
        counts[kind] = len(svc.call("mirror.find", {"kind": kind})
                           .get("matches") or [])
    step("the desktop is populated", counts["desktopItem"] > 0, f"{counts}")

    print("\n4. act — a keystroke, verified in the guest FILESYSTEM")
    # The oracle is the Finder's own work on disk, never the service's report:
    # `performed: true` means the event was dispatched, not that anything
    # happened. Reset first so the trial is independent.
    if h.request("stat", {"path": FOLDER}).get("exists"):
        h.request("delete", {"path": FOLDER})
    res = svc.call("mirror.act.key", {"key": "n", "mods": ["cmd"]})
    time.sleep(4)
    landed = bool(h.request("stat", {"path": FOLDER}).get("exists"))
    step("cmd+N created a folder on disk", landed,
         f"mechanism={res.get('mechanism')} availability={res.get('availability')}")
    if landed:
        h.request("delete", {"path": FOLDER})

    print("\n5. see — a render screenshot, not the guest framebuffer")
    shot = svc.call("mirror.shot")
    png = base64.b64decode(shot["png"]) if shot.get("png") else b""
    if png:
        with open(args.shot, "wb") as fh:
            fh.write(png)
    step("the agent got a rendered view", len(png) > 1000,
         f"{shot.get('width')}x{shot.get('height')}, {len(png)} B -> {args.shot}")

    print("\n6. wait on a predicate")
    w = svc.call("mirror.wait", {"until": {"frontApp": "Finder"},
                                 "timeoutMs": 5000})
    step("the predicate was met", bool(w.get("met")), f"elapsedMs={w.get('elapsedMs')}")

    print("\n7. detach")
    d = svc.raw("mirror.detach", {"session": svc.session})
    step("clean release", bool(d.get("result", {}).get("detached")))

    passed = sum(1 for _, ok, _ in steps if ok)
    print(f"\n--- {passed}/{len(steps)} steps passed ---")
    if passed != len(steps):
        sys.exit(f"FAIL: {len(steps) - passed} step(s) failed")
    print("the agent-facing surface drives the guest: OK")


if __name__ == "__main__":
    main()
