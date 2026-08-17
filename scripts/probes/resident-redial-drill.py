#!/usr/bin/env python3
"""The host-death drill: kill the host ungracefully, watch the resident redial.

WHAT THIS MEASURES, and why it needed its own harness. The resident opens
its OWN connection to the host (`role: resident`), separate from the
application's, and that connection is the only lane a crossing drag can
leave the Macintosh through - the Finder's drag loop starves the
application, so a fact known inside it has to leave through the resident.
On 2026-08-17 an attended metal session produced ZERO resident frames for
its whole length, and the machine needed a reboot: the resident's channel
had gone quiet and had no way back (F2 defect A).

So the question this drill asks is not "does the channel work" - a
healthy run answers that and answers nothing about the defect. It is:
**when the host process dies without saying goodbye, does the resident
come back by itself, and how long does it take?**

WHY A CHILD PROCESS RATHER THAN A CLOSED SOCKET. A socket closed politely
is a FIN, which is the case that already worked. A host that dies is a
process that stops existing mid-conversation, and the only honest way to
produce one is to have one and SIGKILL it. So the listener runs as a
child (`--serve`) and the drill kills it - repeatedly, because a recovery
that works once and latches on the second cycle is the same defect one
round later.

Every probe here is a LISTENER: the guest dials the host, never the other
way round (scripts/probes/README.md).

    usage:
      resident-redial-drill.py --port 12737 --cycles 3 --receipts DIR
      resident-redial-drill.py --serve --port 12737 --events FILE  (internal)
"""
import argparse
import json
import os
import signal
import socket
import struct
import subprocess
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__)))),
    "contract"))
from wire_limits import (  # noqa: E402
    WIRE_CONTRACT_REVISION,
    FRAME_HEADER_BYTES,
    CHANNEL_CONTROL,
    FLAG_END,
)

DEFAULT_CHUNK = 8192


def encode(payload: bytes) -> bytes:
    return struct.pack(">BBHI", CHANNEL_CONTROL, FLAG_END, 0,
                       len(payload)) + payload


class Peer:
    """One dialled-in connection, read incrementally so nothing blocks.

    Single-threaded and select-driven on purpose: the moment a frame
    arrives is the measurement, and a reader thread would make it
    unobservable.
    """

    def __init__(self, sock, addr):
        self.sock = sock
        self.addr = addr
        self.buf = b""
        self.role = None
        self.name = None
        self.greeted = False
        self.next_id = 0

    def send(self, obj: dict) -> None:
        self.sock.sendall(encode(json.dumps(obj).encode("mac_roman",
                                                        "replace")))

    def messages(self):
        chunk = self.sock.recv(65536)
        if not chunk:
            raise ConnectionError("peer closed")
        self.buf += chunk
        while len(self.buf) >= FRAME_HEADER_BYTES:
            channel, _flags, _transfer, length = struct.unpack(
                ">BBHI", self.buf[:FRAME_HEADER_BYTES])
            if len(self.buf) < FRAME_HEADER_BYTES + length:
                return
            payload = self.buf[FRAME_HEADER_BYTES:FRAME_HEADER_BYTES + length]
            self.buf = self.buf[FRAME_HEADER_BYTES + length:]
            if channel != CHANNEL_CONTROL:
                continue
            try:
                yield json.loads(payload.decode("mac_roman"))
            except ValueError:
                yield {"type": "?unparseable", "raw": repr(payload[:120])}


def serve(port: int, events_path: str, ask_mirror_after: float) -> None:
    """Be the host until somebody kills this process."""
    events = open(events_path, "a", buffering=1)

    def note(kind, **fields):
        row = {"t": time.time(), "pid": os.getpid(), "event": kind}
        row.update(fields)
        events.write(json.dumps(row) + "\n")

    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind(("0.0.0.0", port))
    srv.listen(4)
    srv.setblocking(False)
    note("host.up", port=port)

    peers = []
    started = time.time()
    asked = False
    while True:
        import select
        readable, _, _ = select.select([srv] + [p.sock for p in peers],
                                       [], [], 0.25)
        for ready in readable:
            if ready is srv:
                try:
                    conn, addr = srv.accept()
                except BlockingIOError:
                    continue
                conn.setblocking(True)
                conn.settimeout(None)
                peers.append(Peer(conn, addr))
                note("tcp.accept", peer=f"{addr[0]}:{addr[1]}")
                continue
            peer = next(p for p in peers if p.sock is ready)
            try:
                for msg in peer.messages():
                    kind = msg.get("type")
                    if kind == "hello" and not peer.greeted:
                        peer.greeted = True
                        peer.role = msg.get("role") or "guest"
                        peer.name = msg.get("name")
                        note("hello", role=peer.role, name=peer.name,
                             version=msg.get("version"),
                             build=msg.get("build"),
                             peer=f"{peer.addr[0]}:{peer.addr[1]}")
                        peer.send({"type": "hello",
                                   "contract": WIRE_CONTRACT_REVISION,
                                   "side": "host", "version": "drill",
                                   "name": "resident redial drill",
                                   "chunk": DEFAULT_CHUNK})
                    elif kind == "ping":
                        note("ping", role=peer.role, id=msg.get("id"))
                        peer.send({"type": "pong", "id": msg.get("id")})
                    elif kind == "continuity.dragBegin":
                        note("dragBegin", role=peer.role,
                             dragSeq=msg.get("dragSeq"),
                             epoch=msg.get("epoch"),
                             item=(msg.get("item") or {}).get("name"))
                    elif kind in ("command.result", "error"):
                        note("reply", role=peer.role,
                             ok=msg.get("ok"), body=msg)
                    else:
                        note("message", role=peer.role, kind=kind)
            except (ConnectionError, OSError) as exc:
                note("peer.gone", role=peer.role, why=str(exc))
                try:
                    peer.sock.close()
                except OSError:
                    pass
                peers.remove(peer)

        if (not asked and ask_mirror_after > 0
                and time.time() - started >= ask_mirror_after):
            for peer in peers:
                if peer.role != "resident":
                    peer.next_id += 1
                    peer.send({"type": "command.request", "id": peer.next_id,
                               "name": "mirror"})
                    note("asked", role=peer.role, verb="mirror")
                    asked = True


def read_events(path):
    rows = []
    if not os.path.exists(path):
        return rows
    for line in open(path, errors="replace"):
        line = line.strip()
        if line:
            try:
                rows.append(json.loads(line))
            except ValueError:
                pass
    return rows


def wait_for(events_path, predicate, budget, since):
    """Wait for an event, returning it and how long it took."""
    deadline = time.time() + budget
    while time.time() < deadline:
        for row in read_events(events_path):
            if row["t"] >= since and predicate(row):
                return row, row["t"] - since
        time.sleep(0.5)
    return None, None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--cycles", type=int, default=3)
    ap.add_argument("--dwell", type=float, default=45.0,
                    help="seconds a host generation lives before it is "
                         "killed; long enough for a ping to prove the "
                         "conversation is real and not just a hello")
    ap.add_argument("--budget", type=float, default=240.0,
                    help="seconds to wait for a resident to (re)appear")
    ap.add_argument("--receipts", default="/private/tmp/now-rdl-receipts")
    ap.add_argument("--serve", action="store_true")
    ap.add_argument("--events")
    ap.add_argument("--ask-mirror-after", type=float, default=0.0)
    args = ap.parse_args()

    if args.serve:
        serve(args.port, args.events, args.ask_mirror_after)
        return 0

    os.makedirs(args.receipts, exist_ok=True)
    events_path = os.path.join(args.receipts, "drill-events.jsonl")
    open(events_path, "w").close()
    me = os.path.abspath(__file__)

    def spawn(ask_after=0.0):
        return subprocess.Popen(
            [sys.executable, me, "--serve", "--port", str(args.port),
             "--events", events_path, "--ask-mirror-after", str(ask_after)])

    results = []
    child = None
    for cycle in range(args.cycles + 1):
        mark = time.time()
        # The last generation asks the guest for its mirror facts, which is
        # where the resident's own wedge account is read from.
        child = spawn(ask_after=25.0 if cycle == args.cycles else 0.0)
        app, app_dt = wait_for(
            events_path,
            lambda r: r["event"] == "hello" and r.get("role") != "resident",
            args.budget, mark)
        res, res_dt = wait_for(
            events_path,
            lambda r: r["event"] == "hello" and r.get("role") == "resident",
            args.budget, mark)
        print(f"cycle {cycle}: app hello "
              f"{'%.1fs' % app_dt if app_dt else 'NONE'}, resident hello "
              f"{'%.1fs' % res_dt if res_dt else 'NONE'}", flush=True)
        results.append({"cycle": cycle, "generation_started": mark,
                        "app_hello_s": app_dt, "resident_hello_s": res_dt,
                        "resident_name": (res or {}).get("name"),
                        "resident_version": (res or {}).get("version")})
        if res is None:
            print("  the resident never appeared in this generation; "
                  "stopping so the failure is the result rather than a "
                  "later cycle's noise", flush=True)
            break
        # Let the conversation run, so a ping proves it is a connection and
        # not just a completed handshake.
        time.sleep(args.dwell)
        pings = [r for r in read_events(events_path)
                 if r["event"] == "ping" and r.get("role") == "resident"
                 and r["t"] >= mark]
        results[-1]["resident_pings"] = len(pings)
        if cycle == args.cycles:
            time.sleep(10)
            break
        print(f"  SIGKILL host generation {cycle} (pid {child.pid})",
              flush=True)
        child.send_signal(signal.SIGKILL)
        child.wait()
        results[-1]["killed_at"] = time.time()

    if child is not None and child.poll() is None:
        child.send_signal(signal.SIGKILL)
        child.wait()

    rows = read_events(events_path)
    mirror = [r for r in rows if r["event"] == "reply"]
    out = {"port": args.port, "cycles": results,
           "mirror_replies": mirror,
           "dragBegins": [r for r in rows if r["event"] == "dragBegin"]}
    path = os.path.join(args.receipts, "drill-result.json")
    with open(path, "w") as handle:
        json.dump(out, handle, indent=2)
    print(f"\nreceipt: {path}")

    redials = [r["resident_hello_s"] for r in results[1:]
               if r["resident_hello_s"] is not None]
    print(f"resident redials after an ungraceful host death: "
          f"{len(redials)}/{max(len(results) - 1, 0)}")
    if redials:
        print(f"  latencies: " + ", ".join(f"{v:.1f}s" for v in redials))
        print(f"  worst: {max(redials):.1f}s")
    return 0 if len(redials) == max(len(results) - 1, 0) and redials else 1


if __name__ == "__main__":
    raise SystemExit(main())
