#!/usr/bin/env python3
"""Press, drag and grab against one real guest, and say what it published.

This is the emulator instrument for the selection-bind race: the defect
where a press that SELECTS the file it then drags could not publish that
selection at all, so a grab bound the generation before it — and on metal
at 2026-08-15 17:19 transferred `hello.txt` while `main.c` was dragged.

Two facts are being read, and neither can be reasoned into:

  1. DOES A SELECTION ARRIVE WHILE THE BUTTON IS HELD? That is the press
     probe (now-guest-ppc/src/input/continuity_selection.c). Whether the
     Finder answers an Apple Event from inside its own Drag Manager loop
     is an ordering question about another process, and the only honest
     way to learn it is to hold a button down and look.
  2. DOES A GRAB FOR A SUPERSEDED GENERATION REFUSE? That is the
     guarantee — the guest confirms its serve against the Finder before
     any bytes move — and the wrong-file case is exactly a grab for a
     generation the person stopped holding.

WHAT IT ASSERTS BEFORE BELIEVING ANYTHING. A guest answering this port is
not necessarily the build under test: every QEMU guest on this Mac sees
the host as 10.0.2.2, and another lane's VM can dial in (AGENTS.md, the
metal-gate rule). `--require-build` fails unless the guest's hello names
the build stamp it is given. The same rule in the other direction: an
absence here — no mid-gesture selection — is reported as an absence and
never as a pass.

Not a test and not in any gate: it needs a booted guest with a Finder and
a person's idea of where to press. scripts/spin-up-ppc boots one.
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
    """The control lane, plus every unsolicited frame it carried.

    Unsolicited is the whole point here: continuity.selection is never a
    reply, so a reader that only correlates ids sees none of them.
    """

    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""
        self.unsolicited = []

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
        """Read for `seconds`, answering pings, keeping everything seen.

        THE UDP SOCKET IS READ HERE TOO, and it is not optional: leaving
        the guest's acknowledgements unread cost this instrument three
        runs that reported an absence — no selections, no button applies —
        while the guest's own report said `acceptedPackets: 0`. An
        instrument that stops delivering its own input reads exactly like
        the machine doing nothing.
        """
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
        return answer

    def selections(self, since=0.0):
        return [m for m in self.unsolicited
                if m.get("type") == "continuity.selection"
                and m["_at"] >= since]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--udp-host", default=None)
    parser.add_argument("--x", type=int, default=740,
                        help="press point on the guest screen")
    parser.add_argument("--y", type=int, default=60)
    parser.add_argument("--dx", type=int, default=-40)
    parser.add_argument("--dy", type=int, default=40)
    parser.add_argument("--hold", type=float, default=6.0,
                        help="seconds to keep the button down after the drag")
    parser.add_argument("--require-build", default=None,
                        help="refuse to report on a guest whose hello does "
                             "not name this build stamp")
    parser.add_argument("--wait", type=float, default=180)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)
    server.settimeout(args.wait)
    print(f"drag probe listening on {args.host}:{args.port}", flush=True)
    control, tcp_peer = server.accept()
    control.settimeout(args.timeout)
    guest = FramedGuest(control)
    hello = guest.receive()
    guest.send({"type": "hello", "contract": CONTRACT, "side": "host",
                "version": "0", "name": "continuity-drag-probe",
                "chunk": 4096})
    if args.require_build:
        stamp = json.dumps(hello)
        if args.require_build not in stamp:
            raise RuntimeError(
                "this is not the build under test: the guest's hello does "
                f"not name {args.require_build!r}. Every QEMU guest on this "
                "Mac dials 10.0.2.2, so another lane's VM can answer here.")

    nonce_hi, nonce_lo, epoch = 0x13579BDF, 0x2468ACE0, 1
    lease = {"nonceHi": nonce_hi, "nonceLo": nonce_lo, "epoch": epoch}
    guest.send({"type": "continuity.arm", "version": CONTINUITY.version,
                "id": 7101, **lease, "requestedHz": 15, "leaseTicks": 1800})
    arm = guest.drain(args.timeout, want_id=7101)
    if not arm or arm.get("state") != "armed" or not arm.get("udpPort"):
        raise RuntimeError("guest refused Continuity: " + json.dumps(arm))

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((args.host, 0))
    destination = (args.udp_host or tcp_peer[0], int(arm["udpPort"]))
    sequence = 0
    button_generation = 0

    def state(x, y, down, previous_generation=0, previous_flags=0):
        nonlocal sequence
        sequence += 1
        flags = CONTINUITY.flag_inside
        if down:
            flags |= CONTINUITY.flag_primary_down
        payload = CONTINUITY.encode_state(
            nonce_hi, nonce_lo, epoch, sequence, x, y, button_generation,
            15, int(time.monotonic() * 60) & 0xFFFFFFFF, flags,
            previous_generation, previous_flags)
        udp.sendto(payload, destination)
        guest.drain(0.2, udp=udp)

    # 1. Settle: whatever the Finder already had selected, published under
    #    the ordinary poll. This is the generation a press would have bound.
    state(args.x, args.y, False)
    guest.drain(4.0, udp=udp)
    baseline = guest.selections()
    baseline_at = time.monotonic()

    # 2. The press, ON THE POINT GIVEN, and then a drag away from it. One
    #    gesture: this is the case that could never publish its own
    #    selection.
    button_generation += 1
    state(args.x, args.y, True)
    for step in range(1, 6):
        state(args.x + args.dx * step // 5, args.y + args.dy * step // 5,
              True)

    # 3. STILL HELD. Anything that arrives now came from the press probe:
    #    the ordinary poll is gated off for the whole gesture.
    guest.drain(args.hold, udp=udp)
    mid_gesture = guest.selections(since=baseline_at)

    # 4. Release at the press origin, the way the host's cross does.
    previous = button_generation
    button_generation += 1
    state(args.x, args.y, False, previous_generation=previous,
          previous_flags=CONTINUITY.flag_primary_down)
    guest.drain(3.0, udp=udp)
    after_release = guest.selections(since=baseline_at)

    # 5. The two grabs. The superseded one is the wrong-file case; it must
    #    refuse. The current one is the ordinary drag; it must be served.
    latest = (after_release or mid_gesture or baseline or [None])[-1]
    stale_generation = baseline[-1]["generation"] if baseline else 1
    grabs = []
    if latest and latest.get("generation") != stale_generation:
        guest.send({"type": "continuity.grab",
                    "version": CONTINUITY.version, "id": 7201,
                    "epoch": epoch, "generation": stale_generation})
        grabs.append({"asked": stale_generation,
                      "reply": guest.drain(args.timeout, want_id=7201)})
    if latest:
        guest.send({"type": "continuity.grab",
                    "version": CONTINUITY.version, "id": 7202,
                    "epoch": epoch, "generation": latest["generation"]})
        grabs.append({"asked": latest["generation"],
                      "reply": guest.drain(args.timeout, want_id=7202)})

    guest.send({"type": "continuity.disarm", "version": CONTINUITY.version,
                "id": 7301, "epoch": epoch, "reason": "disabled"})
    guest.drain(args.timeout, want_id=7301)
    guest.send({"type": "bye"})

    print(json.dumps({
        "guest": hello,
        "arm": arm,
        "pressPoint": [args.x, args.y],
        "baselineSelections": baseline,
        "midGestureSelections": mid_gesture,
        "afterReleaseSelections": after_release,
        "grabs": grabs,
        "verdict": {
            "pressProbePublished": bool(mid_gesture),
            "selectionMovedUnderThePress": bool(
                latest and baseline
                and latest.get("generation") != baseline[-1].get("generation")
            ),
        },
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - an instrument reports
        print(f"drag probe failed: {error}", file=sys.stderr)
        sys.exit(1)
