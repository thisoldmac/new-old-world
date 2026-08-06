#!/usr/bin/env python3
"""Listen as a NOW host that accepts MORE THAN ONE connection, and write
down which of them keeps speaking while the machine is starved.

    tools/liveness-channel.py --port 5311 --anchor 1702 --wedge 40

READ THIS BEFORE TRUSTING WHAT IT PRINTS, the same warning
`tools/askguest.py` carries and for the same reason. This impersonates a
host to interrogate a REAL guest, so it proves things about the guest and
NOTHING about the host application: the shipped host is `now-host`, whose
starved-vs-gone policy is gated by its own tests. What this settles is the
half those tests cannot reach — whether a real Macintosh actually opens
the second connection, what it says on it, and whether it goes on saying
it while every application on the machine is starved.

WHY IT EXISTS RATHER THAN A FLAG ON askguest.py. That instrument accepts
exactly one connection, which was right while a guest opened exactly one.
Plan 012 § 4 gives the machine a second one from its resident component,
and a listener that accepts one of two would have reported the resident's
dial as a hang. Worse, it would have done so nondeterministically — the
application dials first — which is the failure shape this project
collects.

WHAT A GOOD RUN LOOKS LIKE. Two connections from the same address: one
with no `role` (a session, which is every connection that existed before
this plan) and one with `role: resident`. The resident's `name` and `os`
must be IDENTICAL to the session's — that is not cosmetic, it is how the
host associates the two, and a mismatch means a channel vouching for
nobody.

Then, with `--wedge`, a starvation: a staged applet spins without pumping
for N seconds, the session stops answering, and the resident goes on
pinging through it. The gap in the session's replies is the measurement;
a REFUSAL is not, and neither is a disconnection. Timestamps are printed
on every frame for exactly that reason.
"""

import argparse
import json
import selectors
import socket
import struct
import sys
import time

CONTROL, END = 0, 1
CONTRACT = 2


def frame(payload: bytes) -> bytes:
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


class Peer:
    """One dialling connection, and what it has said."""

    def __init__(self, sock, addr, t0):
        self.sock = sock
        self.addr = addr
        self.t0 = t0
        self.buf = b""
        self.hello = None
        self.role = None
        self.pings = 0
        self.last_seen = time.time()
        self.label = f"{addr[1]}"

    def stamp(self):
        return f"{time.time() - self.t0:7.1f}s"

    def send(self, obj):
        self.sock.sendall(frame(json.dumps(obj).encode()))

    def messages(self):
        """Every complete message now readable. Raises on a closed peer."""
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError("closed")
        self.buf += chunk
        out = []
        while len(self.buf) >= 8:
            _, _, _, length = struct.unpack(">BBHI", self.buf[:8])
            if len(self.buf) < 8 + length:
                break
            payload = self.buf[8:8 + length]
            self.buf = self.buf[8 + length:]
            # Guest JSON carries raw MacRoman bytes in machine names:
            # repair-decode rather than die on somebody's option key.
            out.append(json.loads(payload.decode("utf-8", "replace")))
        return out


def anchor_request(lab, port, verb, args):
    sys.path.insert(0, f"{lab}/mcp-classic")
    from timbottu_mcp_classic.harness import Harness
    return Harness(host="127.0.0.1", port=port,
                   expect_backing={"worker"}).request(verb, args)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=5250)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--wait", type=float, default=240.0,
                    help="seconds to wait for the FIRST connection")
    ap.add_argument("--settle", type=float, default=90.0,
                    help="seconds to watch after the first, for a second")
    ap.add_argument("--run", type=float, default=0.0,
                    help="extra seconds to keep listening after the wedge")
    ap.add_argument("--anchor", type=int, default=0,
                    help="anchor-worker port; required by --wedge")
    ap.add_argument("--lab", default="")
    ap.add_argument("--wedge", type=float, default=0.0,
                    help="starve every application for N seconds, by "
                         "launching the staged NOW Wedge applet")
    ap.add_argument("--probe-every", type=float, default=5.0,
                    help="seconds between `mirror` probes of the session")
    ap.add_argument("--name", default="liveness-channel")
    a = ap.parse_args()

    if a.wedge and not a.anchor:
        return "a --wedge run needs --anchor to launch the applet"

    srv = socket.socket()
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((a.host, a.port))
    srv.listen(8)
    srv.setblocking(False)
    sel = selectors.DefaultSelector()
    sel.register(srv, selectors.EVENT_READ, "listen")

    t0 = time.time()
    peers = {}
    deadline = t0 + a.wait
    wedge_at = None
    wedge_done = False
    next_probe = None
    probe_id = 500
    outstanding = {}          # id -> time sent, for the session only
    gaps = []

    print(f"listening on {a.host}:{a.port}", flush=True)

    while True:
        now = time.time()
        if not peers and now > deadline:
            print("nothing dialled in", flush=True)
            return 2
        if peers and wedge_at is None:
            # The settle window starts when the FIRST connection arrives:
            # the resident dials only after the application has published
            # the endpoint, which it does on its own hello, so the second
            # connection is always later than the first and how much later
            # is one of the things worth writing down.
            wedge_at = now + a.settle
            next_probe = now
        if wedge_at is not None and not wedge_done and now >= wedge_at:
            wedge_done = True
            if a.wedge:
                name = f"NOW Wedge spin {int(a.wedge)}"
                print(f"\n{'':>8} == launching {name} ==", flush=True)
                try:
                    anchor_request(a.lab, a.anchor, "launch", {
                        "path": f"Macintosh HD:TimBotTu:now-dev:{name}"})
                except Exception as exc:
                    # A swallowed launch is how the first version of the
                    # wedge experiment reported "nothing happened" as "no
                    # starvation". It raises here on purpose.
                    print(f"LAUNCH FAILED: {exc}", flush=True)
                    return 3
                deadline = now + a.wedge + a.run + 60
            else:
                deadline = now + a.run

        if wedge_done and now > deadline:
            break

        # Probe the SESSION, not the resident. `mirror` needs the
        # application's own event loop, so a gap in its answers is
        # application starvation — which is the whole measurement.
        # Asking something answered below the application cannot see it
        # (the `hello`-probe trap, drive-loop rule 2e).
        if next_probe is not None and now >= next_probe:
            next_probe = now + a.probe_every
            for p in peers.values():
                if p.role == "resident" or p.hello is None:
                    continue
                probe_id += 1
                outstanding[probe_id] = now
                try:
                    p.send({"type": "command.request", "id": probe_id,
                            "name": "mirror"})
                except OSError:
                    pass

        for key, _ in sel.select(timeout=0.5):
            if key.data == "listen":
                sock, addr = srv.accept()
                sock.setblocking(False)
                peer = Peer(sock, addr, t0)
                peers[sock.fileno()] = peer
                sel.register(sock, selectors.EVENT_READ, peer)
                print(f"{peer.stamp()}  connection {len(peers)} from "
                      f"{addr[0]}:{addr[1]}", flush=True)
                continue
            peer = key.data
            try:
                msgs = peer.messages()
            except (ConnectionError, OSError) as exc:
                print(f"{peer.stamp()}  [{peer.label}] closed ({exc})",
                      flush=True)
                sel.unregister(peer.sock)
                peer.sock.close()
                peers.pop(peer.sock.fileno(), None)
                continue
            for msg in msgs:
                peer.last_seen = time.time()
                kind = msg.get("type")
                if kind == "hello":
                    peer.hello = msg
                    peer.role = msg.get("role", "session")
                    peer.label = peer.role
                    print(f"{peer.stamp()}  [{peer.label}] hello: "
                          + json.dumps(msg), flush=True)
                    peer.send({"type": "hello", "contract": CONTRACT,
                               "side": "host", "version": "0",
                               "name": a.name, "chunk": 4096})
                elif kind == "ping":
                    peer.pings += 1
                    peer.send({"type": "pong", "id": msg.get("id", 0)})
                    print(f"{peer.stamp()}  [{peer.label}] ping "
                          f"#{peer.pings} (id {msg.get('id')})", flush=True)
                elif kind == "command.result":
                    sent = outstanding.pop(msg.get("id"), None)
                    if sent is not None:
                        took = time.time() - sent
                        gaps.append(took)
                        print(f"{peer.stamp()}  [{peer.label}] mirror "
                              f"answered after {took:5.1f}s", flush=True)
                elif kind == "bye":
                    print(f"{peer.stamp()}  [{peer.label}] bye: "
                          + json.dumps(msg), flush=True)

    # ---- the verdict -------------------------------------------------
    print("\n== what the machine did ==", flush=True)
    roles = sorted({p.role or "?" for p in peers.values()})
    print(f"connections still up: {len(peers)}  roles: {roles}", flush=True)
    for p in peers.values():
        print(f"  [{p.label}] pings answered: {p.pings}  "
              f"hello: {json.dumps(p.hello)}", flush=True)
    if gaps:
        print(f"session `mirror` replies: {len(gaps)}, "
              f"slowest {max(gaps):.1f}s", flush=True)
    else:
        print("session answered no `mirror` at all", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
