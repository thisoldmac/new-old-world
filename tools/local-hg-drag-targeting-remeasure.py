#!/usr/bin/env python3
"""Re-measure Drag Manager targeting for a NOW-ORIGINATED promise drag,
with the slice-1B tracking-handler observer (V15) armed.

    tools/local-hg-drag-targeting-remeasure.py --port <wire port> \
        --require-build <fingerprint>

WHY THIS EXISTS. Slice 2 (`feat/hg-drag-dragmgr`) measured a NOW-originated
promise drag with the OLD instrument (a 68K trap shim, V14) and concluded
`inwin=1` while GetMouse read the true point outside the window — targeting
allegedly ignores the driven pointer, with "31k enter/leave oscillations".
Slice 1B (`feat/resident-drag-observe`) built a BETTER instrument — a real
`InstallTrackingHandler` registration (V15) — and used it on a *Finder*-
originated drag, where it measured the opposite: targeting follows the
driven pointer exactly, one message of lag, and the "31k" was loop-rate
churn (~8000 handler calls/sec), not oscillation.

Nobody has yet run V15 against a NOW-originated drag. This script does
exactly that: arm Continuity, publish a `continuity.offer`, drive the
resident's synthetic pointer/button over the same UDP plane
`LiveDragManagerAcceptanceTests.testDropOnTheDesktopMaterialisesTheFile`
uses, holding the button down from inside NOW's own window out to the
Finder's desktop — the same gesture slice 2 measured — and reads V15's own
counters and per-message track ring back off the guest's log ring (`tail`,
area=mirror), rather than trusting the old V14 reading.

It is OBSERVE-ONLY: no product behaviour changes, no ext/ edits. It reuses
the wire vocabulary slice 1's `continuity-drag-probe.py` and the Swift live
acceptance tests already established (continuity.arm, continuity.offer,
Continuity UDP state datagrams, command.request "offer"/"tail").

Run `tools/local-finder-drag.py` against the SAME booted guest, before or
after this script, for the control (a Finder-originated drag through the
act plane) — V15's counters are cumulative for the boot's whole lifetime,
so two runs against one guest are directly comparable the way slice 1B's
two Finder drags were.

Not a test and not in any gate: it needs a booted guest.
scripts/spin-up-ppc boots one.
"""

import argparse
import json
import os
import select
import socket
import struct
import sys
import time
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "contract"))
sys.path.insert(0, os.path.join(ROOT, "tools"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,  # noqa: E402
                         FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)
from continuity_contract import load as load_continuity_contract  # noqa: E402

CONTINUITY = load_continuity_contract(Path(ROOT))


def frame(payload):
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


class FramedGuest:
    """The control lane. Ported from continuity-drag-probe.py's class of
    the same name — generic send/receive/drain plus unsolicited capture,
    with a request()/wait() pair added for command.request/command.result
    round trips (offer, tail)."""

    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""
        self.unsolicited = []
        self._next_id = 9000

    def send(self, obj):
        self.sock.sendall(frame(json.dumps(obj).encode()))

    def receive(self):
        while True:
            while len(self.buffer) >= 8:
                _, _, _, length = struct.unpack(">BBHI", self.buffer[:8])
                if len(self.buffer) < 8 + length:
                    break
                payload = self.buffer[8:8 + length]
                self.buffer = self.buffer[8 + length:]
                return json.loads(payload.decode("utf-8", "replace"))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("guest closed the control connection")
            self.buffer += chunk

    def drain(self, seconds, want_id=None, udp=None):
        deadline = time.monotonic() + seconds
        answer = None
        while time.monotonic() < deadline:
            watch = [self.sock] + ([udp] if udp is not None else [])
            ready, _, _ = select.select(
                watch, [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            if udp is not None and udp in ready:
                udp.recvfrom(256)
                if self.sock not in ready:
                    continue
            message = self.receive()
            stamped = dict(message)
            stamped["_at"] = round(time.monotonic(), 3)
            if message.get("type") == "ping":
                self.send({"type": "pong", "id": message.get("id", 0)})
                continue
            self.unsolicited.append(stamped)
            if want_id is not None and message.get("id") == want_id:
                answer = stamped
                break
        return answer

    def request(self, name, args=None, line=None):
        self._next_id += 1
        req = {"type": "command.request", "id": self._next_id, "name": name}
        if args:
            req["args"] = args
        if line is not None:
            req["line"] = line
        self.send(req)
        return self._next_id

    def wait(self, mid, timeout=30.0, udp=None):
        reply = self.drain(timeout, want_id=mid, udp=udp)
        if reply is None:
            raise RuntimeError(f"no reply for id {mid} within {timeout}s")
        return reply


def tail_pages(guest, max_pages=15, page_lines=40, area="mirror"):
    """Page backward through the guest's log ring, oldest cursor last.
    Returns every [time, text] row seen, newest-first overall (pages are
    returned oldest-within-page-first by the guest; this concatenates page
    by page from the newest page to the oldest requested)."""
    pages = []
    before = None
    last_before = None
    for _ in range(max_pages):
        args = {"lines": page_lines, "area": area}
        if before is not None:
            args["before"] = int(before)
        mid = guest.request("tail", args=args)
        reply = guest.wait(mid)
        out = (reply.get("output") or {})
        page_rows = out.get("tail") or []
        # Each PAGE is oldest-first internally, but successive pages walk
        # BACKWARD in time (newest page fetched first) - so the true
        # chronological order across every page fetched is the pages in
        # REVERSE fetch order, each kept in its own oldest-first order.
        pages.append(page_rows)
        log = {k: v for k, v in (out.get("log") or [])}
        nxt = log.get("next")
        if not nxt:
            break
        # THE VALUE IS A JSON STRING ("next" prints its %lu inside quotes,
        # matching every other `tail` row), but `now_json_find_u32` reads
        # raw digits after the colon and returns the fallback (0 = newest)
        # on a quote — so passing it back verbatim re-requests the same
        # newest page forever. Cast to int so the arg is unquoted JSON.
        before = int(nxt)
        if before == last_before:
            break
        last_before = before
    rows = []
    for page_rows in reversed(pages):
        rows.extend(page_rows)
    return rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--udp-host", default=None)
    ap.add_argument("--epoch", type=int, default=9001)
    ap.add_argument("--start-x", type=int, default=300)
    ap.add_argument("--start-y", type=int, default=240)
    ap.add_argument("--drop-x", type=int, default=None,
                    help="defaults to NOW_DRAG_DROP or 300")
    ap.add_argument("--drop-y", type=int, default=None,
                    help="defaults to NOW_DRAG_DROP or 570")
    ap.add_argument("--require-build", default=None)
    ap.add_argument("--wait", type=float, default=240)
    ap.add_argument("--timeout", type=float, default=15)
    ap.add_argument("--tail-only", action="store_true",
                    help="skip the drag; just connect and page the "
                         "guest's own mirror log (V15's counters are "
                         "cumulative for the boot, so this re-reads "
                         "whatever an earlier run or a Finder-drag "
                         "control already produced)")
    ap.add_argument("--tail-pages", type=int, default=20)
    args = ap.parse_args()

    target = os.environ.get("NOW_DRAG_DROP", "")
    parts = [p for p in target.split(",") if p]
    drop_x = args.drop_x if args.drop_x is not None else (
        int(parts[0]) if len(parts) == 2 else 300)
    drop_y = args.drop_y if args.drop_y is not None else (
        int(parts[1]) if len(parts) == 2 else 570)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)
    server.settimeout(args.wait)
    print(f"hg-drag targeting remeasure listening on {args.host}:{args.port}",
          flush=True)
    control, tcp_peer = server.accept()
    control.settimeout(args.timeout)
    guest = FramedGuest(control)
    hello = guest.receive()
    guest.send({"type": "hello", "contract": CONTRACT, "side": "host",
                "version": "0", "name": "hg-drag-targeting-remeasure",
                "chunk": 4096})
    print("guest hello:", json.dumps(hello), flush=True)
    if args.require_build:
        stamp = json.dumps(hello)
        if args.require_build not in stamp:
            raise RuntimeError(
                "this is not the build under test: the guest's hello does "
                f"not name {args.require_build!r}. Every QEMU guest on this "
                "Mac dials 10.0.2.2, so another lane's VM can answer here.")

    if args.tail_only:
        print("\n=== paging the guest's own 'mirror' log ===", flush=True)
        rows = tail_pages(guest, max_pages=args.tail_pages)
        for stamp, text in rows:
            print(f"  {stamp}  {text}")
        mid = guest.request("offer")
        report = guest.wait(mid)
        print("offer report:", json.dumps(report), flush=True)
        guest.send({"type": "bye"})
        print(json.dumps({"guest": hello, "logRows": rows,
                          "report": report}, indent=2, sort_keys=True))
        return 0

    nonce_hi, nonce_lo, epoch = 0x484731D5, 0x4147445F, args.epoch
    guest.send({"type": "continuity.arm", "version": CONTINUITY.version,
                "id": 9101, "nonceHi": nonce_hi, "nonceLo": nonce_lo,
                "epoch": epoch, "requestedHz": 30, "leaseTicks": 3600})
    arm = guest.drain(args.timeout, want_id=9101)
    if not arm or arm.get("state") != "armed" or not arm.get("udpPort"):
        raise RuntimeError("guest refused Continuity: " + json.dumps(arm))
    print("continuity armed:", json.dumps(arm), flush=True)
    udp_port = int(arm["udpPort"])

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((args.host if args.host != "0.0.0.0" else "0.0.0.0", 0))
    destination = (args.udp_host or tcp_peer[0], udp_port)

    sequence = 0
    generation = 0

    def send_state(h, v, down):
        nonlocal sequence
        sequence += 1
        flags = CONTINUITY.flag_inside
        if down:
            flags |= CONTINUITY.flag_primary_down
        payload = CONTINUITY.encode_state(
            nonce_hi, nonce_lo, epoch, sequence, h, v, generation, 30,
            int(time.monotonic() * 60) & 0xFFFFFFFF, flags)
        udp.sendto(payload, destination)

    # Settle the pointer inside NOW's own window before anything else.
    for _ in range(10):
        send_state(args.start_x, args.start_y, False)
        guest.drain(0.03, udp=udp)

    # Publish the offer this drag will carry. A REAL type/creator: the
    # host-side fixture note in docs/open-issues.md is explicit that an
    # unclassifiable ('????') promise is a different question than the one
    # this run is for.
    item = {
        "name": "HGRemeasure.txt", "fileType": "TEXT", "creator": "ttxt",
        "dataSize": 4096, "isFolder": False,
    }
    guest.send({"type": "continuity.offer", "version": CONTINUITY.version,
                "epoch": epoch, "generation": 1, "item": item})
    guest.drain(0.5, udp=udp)

    mid = guest.request("offer", line="--drag")
    armed = guest.wait(mid, udp=udp)
    print("offer --drag reply:", json.dumps(armed), flush=True)
    if not armed.get("ok"):
        raise RuntimeError("offer --drag refused: " + json.dumps(armed))

    generation += 1
    # Hold at the start point so the arm ripens and TrackDrag is running
    # before anything moves — same shape as the Swift live test.
    for _ in range(40):
        send_state(args.start_x, args.start_y, True)
        guest.drain(0.03, udp=udp)

    print(f"driving from ({args.start_x},{args.start_y}) to "
          f"({drop_x},{drop_y}) with the button held", flush=True)
    for step in range(1, 31):
        v = args.start_y + (drop_y - args.start_y) * step // 30
        h = args.start_x + (drop_x - args.start_x) * step // 30
        send_state(h, v, True)
        guest.drain(0.04, udp=udp)

    for _ in range(15):
        send_state(drop_x, drop_y, True)
        guest.drain(0.04, udp=udp)

    generation += 1
    for _ in range(20):
        send_state(drop_x, drop_y, False)
        guest.drain(0.04, udp=udp)

    print("button released; waiting for the promise to settle", flush=True)
    guest.drain(6.0, udp=udp)

    mid = guest.request("offer")
    report = guest.wait(mid, udp=udp)
    print("offer report after the drop:", json.dumps(report), flush=True)

    print("\n=== paging the guest's own 'mirror' log ===", flush=True)
    rows = tail_pages(guest, max_pages=20)
    for stamp, text in rows:
        print(f"  {stamp}  {text}")

    guest.send({"type": "continuity.disarm", "version": CONTINUITY.version,
                "id": 9301, "epoch": epoch, "reason": "disabled"})
    guest.drain(args.timeout, want_id=9301)
    guest.send({"type": "bye"})

    print(json.dumps({
        "guest": hello,
        "arm": arm,
        "start": [args.start_x, args.start_y],
        "drop": [drop_x, drop_y],
        "offerDragReply": armed,
        "reportAfterDrop": report,
        "logRows": rows,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - an instrument reports
        print(f"hg-drag targeting remeasure failed: {error}",
              file=sys.stderr)
        sys.exit(1)
