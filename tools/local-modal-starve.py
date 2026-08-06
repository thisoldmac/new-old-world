#!/usr/bin/env python3
"""Is NOW STARVED while a modal is up, or merely slow? One row per probe.

    tools/local-modal-starve.py --port 5590 --anchor 5591 \\
        --expect-build 711abdbd --wedge modal --seconds 45

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody.

WHY IT EXISTS. Michelle's session of 2026-08-06 read `request_ms=12041
decode_ms=98` with a foreign application's modal up — the guest walking in
2 ms of its own phases and then taking twelve seconds to answer. Three
readings in this tree disagree about whether a modal starves the machine
at all (plan 012 §5 says a modal "never starved, 71 s"; the arm-latency
entry says "under a modal the wait IS the modal, 30.023 s"), and the
ledger flags the contradiction as unresolved. This settles it by
measuring three things at once, which is what none of those runs did:

  1. **The application's latency**, as a DISTRIBUTION, not a yes/no. A
     probe that asks "did anything answer inside the window" cannot tell
     12 s from 30 ms, and both earlier runs asked exactly that. Every
     probe here is timestamped and every answer is kept, including the
     ones that arrive late.
  2. **The machine's own liveness, from BELOW the application.** The
     resident component (plan 012 §4) holds its OWN connection and pings
     it on a 5 s Time Manager tick. Those pings are read on a separate
     socket in a separate thread — the only background thread here, and
     it exists because the arrival TIME of a resident ping during a
     twelve-second application stall is the whole measurement, and a
     reader blocked on the application's socket would timestamp them all
     at the end. If the resident keeps ticking while the session cannot
     answer, the machine is running and NOW is not being scheduled: that
     is starvation, measured rather than argued.
  3. **How much time NOW got**, from the guest's own event loop.
     `wirestat` keeps a histogram of the interval between `conn_service`
     passes. Reset before the wedge, read after, its `pass max` is the
     longest the loop went unserviced — so "no time at all" (max ~= the
     wedge's whole duration) and "a little, slowly" (max ~= 1 s, n
     climbing) are different readings rather than the same guess.

WHAT IT REFUSES. A guest whose hello build is not `--expect-build`: every
QEMU guest on this Mac sees the host as 10.0.2.2 and any session's VM can
answer this listener (AGENTS.md). And a `--wedge` whose launch failed —
raised, not swallowed, because a launch that did not happen reported as
"no starvation" once already (plan 012 §5).
"""

import argparse
import json
import os
import socket
import struct
import sys
import threading
import time

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
sys.path.insert(0, os.path.join(ROOT, "contract"))

import nowwire  # noqa: E402
from scene import SceneUnavailable  # noqa: E402
from wire_limits import (CHANNEL_CONTROL, FLAG_END,  # noqa: E402
                         WIRE_CONTRACT_REVISION)


def frame(payload: bytes) -> bytes:
    return struct.pack(">BBHI", CHANNEL_CONTROL, FLAG_END, 0,
                       len(payload)) + payload


class ResidentWatch(threading.Thread):
    """The second connection, watched live. See the module docstring for why
    this one is threaded when nothing else here is."""

    daemon = True

    def __init__(self, srv, t0):
        super().__init__()
        self.srv = srv
        self.t0 = t0
        self.events = []          # (elapsed, text)
        self.hello = None
        self.pings = 0
        self.stop = False

    def note(self, text):
        self.events.append((time.time() - self.t0, text))

    def run(self):
        try:
            self.srv.settimeout(1.0)
            while not self.stop:
                try:
                    conn, addr = self.srv.accept()
                except socket.timeout:
                    continue
                except OSError:
                    return
                self.note(f"connection from {addr[0]}:{addr[1]}")
                self.serve(conn)
        except Exception as exc:                     # noqa: BLE001
            self.note(f"watch died: {exc!r}")

    def serve(self, conn):
        buf = b""
        conn.settimeout(1.0)
        while not self.stop:
            try:
                chunk = conn.recv(65536)
            except socket.timeout:
                continue
            except OSError:
                return
            if not chunk:
                self.note("closed")
                return
            buf += chunk
            while len(buf) >= 8:
                _, _, _, length = struct.unpack(">BBHI", buf[:8])
                if len(buf) < 8 + length:
                    break
                payload, buf = buf[8:8 + length], buf[8 + length:]
                msg = json.loads(payload.decode("utf-8", "replace"))
                kind = msg.get("type")
                if kind == "hello":
                    self.hello = msg
                    self.note(f"hello role={msg.get('role')} "
                              f"name={msg.get('name')!r}")
                    conn.sendall(frame(json.dumps({
                        "type": "hello", "contract": WIRE_CONTRACT_REVISION,
                        "side": "host", "version": "0",
                        "name": "local-modal-starve", "chunk": 4096,
                    }).encode()))
                elif kind == "ping":
                    self.pings += 1
                    self.note(f"ping #{self.pings}")
                    conn.sendall(frame(json.dumps({
                        "type": "pong", "id": msg.get("id", 0)}).encode()))
                else:
                    self.note(f"{kind}")


def anchor(port, verb, args, lab):
    sys.path.insert(0, f"{lab}/mcp-classic")
    from timbottu_mcp_classic.harness import Harness
    return Harness(host="127.0.0.1", port=port,
                   expect_backing={"worker"}).request(verb, args)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5590)
    ap.add_argument("--anchor", type=int, default=5591)
    ap.add_argument("--lab", default=os.environ.get(
        "NOW_LAB_ROOT", os.path.expanduser("~/Lab/Code/timbottu")))
    ap.add_argument("--expect-build", default=None)
    ap.add_argument("--wait", type=float, default=240.0)
    ap.add_argument("--wedge", default="",
                    help="spin | modal | scan — the staged applet's mode")
    ap.add_argument("--seconds", type=int, default=45,
                    help="the wedge's own duration; it lets go by itself")
    ap.add_argument("--script", default="",
                    help="AppleScript source to run instead of a wedge "
                         "(raises a REAL application's modal)")
    ap.add_argument("--baseline", type=int, default=6,
                    help="probes before the wedge")
    ap.add_argument("--after", type=float, default=30.0,
                    help="seconds of probing after the wedge's deadline")
    ap.add_argument("--gap", type=float, default=1.0,
                    help="seconds between probes")
    ap.add_argument("--probe", default="scene",
                    help="scene | mirror — what one probe asks for")
    a = ap.parse_args()

    t0 = time.time()
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", a.port))
    srv.listen(4)
    srv.settimeout(a.wait)
    print(f"listening on 0.0.0.0:{a.port}", flush=True)
    conn, peer = srv.accept()
    conn.settimeout(20.0)
    link = nowwire.GuestLink(conn, {}, identity_name="local-modal-starve")
    link.hello = link._gate()
    conn.settimeout(None)
    build = str(link.hello.get("build") or "")
    print(f"session: {link.hello.get('name')!r} build {build}", flush=True)
    if a.expect_build and a.expect_build not in build:
        raise SystemExit(f"WRONG BUILD: wanted {a.expect_build!r}, got "
                         f"{build!r}. Refusing to measure.")

    watch = ResidentWatch(srv, t0)
    watch.start()

    rows = []

    def probe(tag):
        """One request, timestamped. A failure is recorded, never raised: a
        refusal and a timeout are different facts and both are data."""
        sent = time.time()
        detail = ""
        try:
            if a.probe == "scene":
                doc, env = link.scene(full=False, timeout=90.0)
                detail = (f"windows={len(doc.get('windows') or [])} "
                          f"walk={(env or {}).get('walkMs')}")
            else:
                out = link.command("mirror", timeout=90.0)
                detail = "ok"
        except (SceneUnavailable, nowwire.GuestError, TimeoutError,
                socket.timeout) as exc:
            detail = f"FAILED {type(exc).__name__}: {exc}"
        took = time.time() - sent
        rows.append((tag, sent - t0, took, detail))
        print(f"{sent - t0:7.1f}s  {tag:<9} {took * 1000:8.0f} ms  {detail}",
              flush=True)
        return took

    print("\n== baseline ==", flush=True)
    link.command("wirestat", line="wirestat reset", timeout=60.0)
    for _ in range(a.baseline):
        probe("before")
        time.sleep(a.gap)

    # The wedge, or the real modal. Either way the START is a fact rather
    # than an inference: it is stamped here, and a failed launch raises.
    print("\n== the wedge ==", flush=True)
    started = time.time()
    if a.script:
        # A real application's modal, raised over the wire. This is
        # deliberately sent with send_async and NOT waited for: the script
        # verb does not return until the application it drives does, and
        # under a modal that is the whole point.
        mid = link.send_async("script", {"source": a.script,
                                         "timeoutMs": 5000})
        print(f"{started - t0:7.1f}s  script sent (id {mid}): "
              f"{a.script[:70]}", flush=True)
    elif a.wedge:
        name = f"NOW Wedge {a.wedge} {a.seconds}"
        res = anchor(a.anchor, "launch",
                     {"path": f"Macintosh HD:TimBotTu:now-dev:{name}"}, a.lab)
        print(f"{started - t0:7.1f}s  launched {name}: {res}", flush=True)
    deadline = started + a.seconds + a.after
    while time.time() < deadline:
        tag = "during" if time.time() - started < a.seconds else "after"
        probe(tag)
        time.sleep(a.gap)

    print("\n== the guest's own loop, over the whole run ==", flush=True)
    try:
        out = link.command("wirestat", timeout=90.0)
        for label, value in out.get("wirestat") or []:
            if label.startswith("pass") or label.startswith("Sleep") \
                    or label.startswith("Idle") or label.startswith("Wake"):
                print(f"  {label:<28} {value}", flush=True)
    except Exception as exc:                          # noqa: BLE001
        print(f"  wirestat failed: {exc}", flush=True)

    print("\n== the resident, below the application ==", flush=True)
    watch.stop = True
    if not watch.events:
        print("  NOTHING dialled a second connection — no resident channel "
              "on this guest, so this run says nothing about starvation "
              "versus death.", flush=True)
    for elapsed, text in watch.events:
        print(f"{elapsed:7.1f}s  [resident] {text}", flush=True)

    print("\n== the distribution ==", flush=True)
    for phase in ("before", "during", "after"):
        took = sorted(r[2] for r in rows if r[0] == phase)
        if not took:
            continue
        fail = sum(1 for r in rows if r[0] == phase and "FAILED" in r[3])
        print(f"  {phase:<7} n={len(took):<3} median={took[len(took)//2]*1000:8.0f} ms"
              f"  max={took[-1]*1000:8.0f} ms  failed={fail}", flush=True)
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
