"""Prove the resident keeps running while every application is starved.

The premise the whole liveness plane rests on, and the deliverable of
plan 012 § 3. `ext/src/now_liveness.c` bumps `liveness_ticks` from a Time
Manager task every 5 s and **nothing else in the system writes that
word**, so its value either side of a deliberate starvation says whether
anything on this machine kept running while no application did.

The shape of the measurement matters, and it is not the obvious one.
During `tools/guest-wedge spin` the NOW application is starved too, so it
cannot be asked anything WHILE the wedge runs — the counter has to be
read before and after, and the claim is about the DELTA against elapsed
wall time. That is not a weaker measurement: a counter that only a
five-second interrupt writes cannot gain 12 across 60 s unless it was
ticking through the middle, and the middle is exactly the span in which a
second, independent, application-level probe went silent.

So there are two observers and they must disagree:

  * `stat` to the anchor worker — a background-only application on its
    own TCP port, sharing nothing with NOW but the machine. It needs the
    worker's own main loop, and it is expected to GO SILENT. (`hello`
    would not: measured 2026-08-05, it kept answering right through a
    spin wedge, because it is answered below the application. Same class
    as `probe-oracles-were-blind`.)
  * `livenessTicks` from the guest's `mirror` verb, read either side. It
    is expected to KEEP CLIMBING across the same span.

If both keep going, the wedge did not starve anything and the run proves
nothing — that is the failure this instrument most needs to report
honestly, because it looks like success. It is checked and named.

    python3 tools/liveness-experiment.py --wire 5277 --anchor 1702

The wire connection is held open for the whole run, so the second read is
the same session as the first.
"""
import argparse
import json
import socket
import struct
import sys
import time

sys.path.insert(0, "/Users/michelle/Lab/Code/timbottu/mcp-classic")
from timbottu_mcp_classic.harness import Harness  # noqa: E402

CONTROL, END, CONTRACT = 0, 1, 1


class Wire:
    """One held host session, exactly as tools/askguest.py speaks it."""

    def __init__(self, port, wait):
        srv = socket.socket()
        srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        srv.bind(("127.0.0.1", port))
        srv.listen(1)
        srv.settimeout(wait)
        print(f"listening on :{port} for up to {wait:.0f}s", flush=True)
        self.sock, peer = srv.accept()
        srv.close()
        self.sock.settimeout(120.0)
        self.buf = b""
        self.mid = 100
        hello = self.read()
        print("guest hello: " + json.dumps(hello), flush=True)
        self.send({"type": "hello", "contract": CONTRACT, "side": "host",
                   "version": "0", "name": "liveness-experiment",
                   "chunk": 4096})

    def send(self, obj):
        payload = json.dumps(obj).encode()
        self.sock.sendall(
            struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload)

    def read(self):
        while True:
            while len(self.buf) >= 8:
                _, _, _, n = struct.unpack(">BBHI", self.buf[:8])
                if len(self.buf) < 8 + n:
                    break
                p, self.buf = self.buf[8:8 + n], self.buf[8 + n:]
                return json.loads(p.decode("utf-8", "replace"))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("guest closed the connection")
            self.buf += chunk

    def ask(self, name):
        self.mid += 1
        self.send({"type": "command.request", "id": self.mid, "name": name})
        while True:
            msg = self.read()
            if msg.get("type") == "ping":
                # The guest's own keepalive. Answering it is not decoration
                # here: this run deliberately leaves the wire quiet for
                # longer than the contract's 30 s silence window.
                self.send({"type": "pong", "id": msg.get("id", 0)})
                continue
            if msg.get("id") == self.mid:
                return msg


def liveness_ticks(wire):
    """The counter and the moment it was read, as one fact."""
    reply = wire.ask("mirror")
    t = time.time()
    blob = json.dumps(reply)
    try:
        ext = reply["output"]["mirror"]["extension"]
        ticks = ext["livenessTicks"]
        print(f"  (capabilities {ext.get('capabilities')} — bit 5 (32) is "
              f"the liveness vehicle)", flush=True)
    except (KeyError, TypeError):
        # Print the whole reply rather than a tidy error: if the field has
        # moved, the thing worth seeing is where it went.
        print("no livenessTicks in: " + blob, flush=True)
        raise SystemExit("the guest did not report livenessTicks")
    return ticks, t


def worker_alive(anchor, timeout=2.0):
    """Application-level, on purpose — see the module docstring."""
    socket.setdefaulttimeout(timeout)
    try:
        h = Harness(host="127.0.0.1", port=anchor, expect_backing={"worker"})
        return bool(h.request(
            "stat", {"path": "Macintosh HD:System Folder"}).get("exists"))
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--wire", type=int, default=5277)
    ap.add_argument("--anchor", type=int, default=1700)
    # `modal` is the NEGATIVE CONTROL and the reason this is a flag at all.
    # Measured 2026-08-05, a modal sitting there starves nothing, so a run
    # in that mode must reach INCONCLUSIVE — which is how this instrument
    # was watched to fail rather than merely watched to pass.
    ap.add_argument("--mode", default="spin",
                    choices=("spin", "modal", "scan"))
    ap.add_argument("--seconds", type=int, default=25,
                    help="how long the wedge is asked to spin")
    ap.add_argument("--watch", type=int, default=75)
    ap.add_argument("--wait", type=float, default=240.0)
    a = ap.parse_args()

    wire = Wire(a.wire, a.wait)
    before, t_before = liveness_ticks(wire)
    print(f"livenessTicks before: {before}", flush=True)

    if not worker_alive(a.anchor):
        raise SystemExit("the anchor worker was not answering before we began")

    path = f"Macintosh HD:Desktop Folder:NOW Wedge {a.mode} {a.seconds}"
    socket.setdefaulttimeout(8.0)
    h = Harness(host="127.0.0.1", port=a.anchor, expect_backing={"worker"})
    reply = h.request("launch", {"path": path})
    if not reply.get("launched"):
        # Never swallowed: a failed launch reports as "nothing was starved",
        # which reads as a healthy machine (drive-loop rule 2e).
        raise SystemExit(f"the guest refused the launch: {reply}")
    print(f"wedge launched, psn {reply.get('serialLo')}", flush=True)

    t0 = time.time()
    samples = []
    while time.time() - t0 < a.watch:
        samples.append((round(time.time() - t0, 1), worker_alive(a.anchor)))
        if (any(not ok for _, ok in samples)
                and len(samples) >= 2 and samples[-1][1] and samples[-2][1]):
            break
        time.sleep(1.0)

    print("  worker timeline:",
          "".join("." if ok else "X" for _, ok in samples), flush=True)
    silent = [t for t, ok in samples if not ok]

    after, t_after = liveness_ticks(wire)
    elapsed = t_after - t_before
    gained = after - before
    expect = elapsed / 5.0
    print(f"livenessTicks after: {after}", flush=True)
    print(f"  gained {gained} over {elapsed:.0f}s "
          f"(a 5 s cadence predicts about {expect:.0f})", flush=True)

    if not silent:
        print("VERDICT: INCONCLUSIVE — the worker never went silent, so "
              "nothing here was starved and the counter proves nothing.",
              flush=True)
        return 2
    print(f"  worker silent from {silent[0]:.0f}s to {silent[-1]:.0f}s",
          flush=True)
    # Two thirds of the predicted rate: generous, because the point is that
    # the counter kept MOVING through the starvation, not that a Time
    # Manager task on an emulated Mac keeps host-accurate time.
    if gained >= expect * 0.66:
        print("VERDICT: the resident kept running while the application "
              "layer did not.", flush=True)
        return 0
    print("VERDICT: the counter did NOT keep up — the vehicle either "
          "stopped or never started.", flush=True)
    return 1


if __name__ == "__main__":
    sys.exit(main())
