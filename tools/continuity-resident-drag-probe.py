#!/usr/bin/env python3
"""WHEN does the host learn which file is being dragged — and from whom?

The question this instrument exists for has one number in it. The
dragged file's identity is read by the resident inside the Finder's own
Drag Manager loop, and it used to be published only by the PowerPC
application, which gets no task time until that loop ends: measured
2026-08-16, the identity reached the host 462 ticks after the drag began
and 14 ticks after it ENDED. The crossing that needed it happens in
between.

So the resident now sends it itself, over its own liveness channel, from
the tracking handler. Whether that actually arrives MID-GESTURE is an
ordering fact about two processes and a network stack, and the only
honest way to learn it is to hold a button down and watch the socket.

WHAT MAKES THIS DIFFERENT FROM tools/continuity-drag-probe.py: that one
listens to the APPLICATION. This one accepts BOTH connections a machine
running the resident makes — the application's session and the
resident's liveness channel — and timestamps every frame on each, so
"which sender said it first" is a subtraction rather than a belief.

THREE THINGS IT REPORTS, and it reports absence as absence:

  1. `dragBegin` arrival against the button. Held-down arrival is the
     whole point; an arrival after the release is the old behaviour with
     a new frame on it, and is reported as exactly that.
  2. The JOIN. The application's own `continuity.selection` for the same
     gesture must carry the same `dragSeq` and supply the generation.
     Same name = one gesture; different name = a real disagreement.
  3. The bytes. A grab for the joined generation, drained to FLAG_END,
     with a sha256 — because an announced transfer that is never read
     proves the announcement and nothing else.

Not a test and not in any gate: it needs a booted guest, a Finder, and a
point on the screen where an UNSELECTED icon is. scripts/spin-up-ppc
boots one.
"""

import argparse
import hashlib
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
from wire_limits import (CHANNEL_BULK as BULK,  # noqa: E402
                         CHANNEL_CONTROL as CONTROL,
                         FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)
from continuity_contract import load as load_continuity_contract  # noqa: E402

CONTINUITY = load_continuity_contract(Path(ROOT))


def frame(payload):
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


class Link:
    """One framed connection, with a stamp on everything it carried.

    Both channels are decoded here rather than only the control one: a
    grab is answered down the ordinary file lane, and an instrument that
    could not read the bulk frames would report an announced transfer as
    a delivered one — which is precisely the gap the last round closed.
    """

    def __init__(self, sock, role):
        self.sock = sock
        self.role = role
        self.buffer = b""
        self.messages = []
        self.bulk = {}          # transfer id -> bytes
        self.bulk_ended = set()

    def fileno(self):
        return self.sock.fileno()

    def send(self, obj):
        self.sock.sendall(frame(json.dumps(obj).encode()))

    def pump(self):
        """Read whatever is waiting; return the control messages it held."""
        chunk = self.sock.recv(65536)
        if not chunk:
            raise RuntimeError(f"{self.role} closed the connection")
        self.buffer += chunk
        fresh = []
        while len(self.buffer) >= 8:
            channel, flags, transfer, length = struct.unpack(
                ">BBHI", self.buffer[:8])
            if len(self.buffer) < 8 + length:
                break
            payload = self.buffer[8:8 + length]
            self.buffer = self.buffer[8 + length:]
            if channel == BULK:
                self.bulk[transfer] = self.bulk.get(transfer, b"") + payload
                if flags & END:
                    self.bulk_ended.add(transfer)
                continue
            message = json.loads(payload.decode("utf-8", "replace"))
            message["_at"] = round(time.monotonic(), 4)
            message["_from"] = self.role
            self.messages.append(message)
            fresh.append(message)
        return fresh

    def of_type(self, name, since=0.0):
        return [m for m in self.messages
                if m.get("type") == name and m["_at"] >= since]


class Rig:
    """The application's session and the resident's channel, together.

    They are two connections from ONE machine and they are accepted the
    same way, because the host does: the resident's hello declares
    `role: resident` and shares its machine's name deliberately.
    """

    def __init__(self, server, timeout):
        self.server = server
        self.timeout = timeout
        self.app = None
        self.resident = None
        self.hellos = {}

    def accept_one(self):
        sock, _ = self.server.accept()
        sock.settimeout(self.timeout)
        link = Link(sock, "pending")
        while not link.messages:
            link.pump()
        hello = link.messages[0]
        if hello.get("type") != "hello":
            raise RuntimeError(f"first frame was not a hello: {hello}")
        link.role = hello.get("role") or "session"
        self.hellos[link.role] = hello
        link.send({"type": "hello", "contract": CONTRACT, "side": "host",
                   "version": "0", "name": "continuity-resident-drag-probe",
                   "chunk": 4096})
        if link.role == "resident":
            self.resident = link
        else:
            self.app = link
        return link

    def links(self):
        return [x for x in (self.app, self.resident) if x is not None]

    def pump(self, seconds, udp=None):
        """Read every socket for `seconds`, answering pings on both.

        The resident's channel pings too, and an unanswered ping is a
        channel the machine will eventually drop — which would end the
        very lane the measurement is about.
        """
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            watch = self.links() + ([udp] if udp is not None else [])
            ready, _, _ = select.select(
                watch, [], [], max(0, deadline - time.monotonic()))
            if not ready:
                break
            if udp is not None and udp in ready:
                udp.recvfrom(256)
            for link in self.links():
                if link not in ready:
                    continue
                for message in link.pump():
                    if message.get("type") == "ping":
                        link.send({"type": "pong",
                                   "id": message.get("id", 0)})


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True)
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--udp-host", default=None)
    parser.add_argument("--x", type=int, default=0)
    parser.add_argument("--y", type=int, default=0)
    parser.add_argument("--pick", default=None,
                        help="press at the centre of this desktop item, as "
                             "the FINDER reports its bounds")
    parser.add_argument("--dx", type=int, default=-40)
    parser.add_argument("--dy", type=int, default=40)
    parser.add_argument("--hold", type=float, default=8.0,
                        help="seconds the button stays down after the drag")
    parser.add_argument("--require-build", default=None)
    parser.add_argument("--wait", type=float, default=240)
    parser.add_argument("--timeout", type=float, default=10)
    parser.add_argument("--resident-wait", type=float, default=90,
                        help="seconds to wait for the resident to dial")
    args = parser.parse_args()

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(4)
    server.settimeout(args.wait)
    print(f"resident drag probe listening on {args.host}:{args.port}",
          file=sys.stderr, flush=True)

    def note(text):
        print(f"[probe] {text}", file=sys.stderr, flush=True)
    rig = Rig(server, args.timeout)
    first = rig.accept_one()
    tcp_peer = first.sock.getpeername()
    if args.require_build and rig.app is not None:
        if args.require_build not in json.dumps(rig.app.messages[0]):
            raise RuntimeError(
                "this is not the build under test: the guest's hello does "
                f"not name {args.require_build!r}.")

    # THE RESIDENT DIALS SECOND, and only once the application has
    # published the endpoint into the shared table. Waiting for it is not
    # optional: without this channel there is nothing to measure, and a
    # run that quietly proceeded would report the old behaviour as a
    # result rather than as a missing precondition.
    server.settimeout(args.resident_wait)
    resident_deadline = time.monotonic() + args.resident_wait
    while rig.resident is None and time.monotonic() < resident_deadline:
        try:
            rig.accept_one()
        except socket.timeout:
            break
        rig.pump(0.2)
    if rig.app is None:
        raise RuntimeError("no application session dialled in")
    resident_present = rig.resident is not None
    note(f"connections: app={rig.app is not None} "
         f"resident={resident_present}")

    # ---- THE RIG, and it is three facts the product does not supply ----
    #
    # 1. NOW MUST BE HIDDEN, not merely behind. Its window lies over the
    #    desktop and a press that lands on it is a press on the wrong
    #    application. `hide` rather than `front Finder` alone: fronting
    #    reorders, hiding exposes. An earlier round reported a clean
    #    `calls=0` for want of this and read it as a broken plane.
    # 2. THE FINDER MUST BE FRONT, because the tracking-handler
    #    registration only ever happens in a process while it pumps, and
    #    because the press is dequeued by whoever is frontmost.
    # 3. THE POINT MUST BE AN UNSELECTED ICON, asked of the Finder rather
    #    than guessed from a screenshot — the whole gesture under test is
    #    "a file nobody selected".
    def request(link, name, args=None, timeout=60):
        link._probe_id = getattr(link, "_probe_id", 8000) + 1
        message = {"type": "command.request", "id": link._probe_id,
                   "name": name}
        if args:
            message.update(args)
        link.send(message)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            rig.pump(0.5)
            for m in link.messages:
                if (m.get("type") == "command.result"
                        and m.get("id") == link._probe_id):
                    return m
        raise RuntimeError(f"{name} never answered")

    def script(source):
        reply = request(rig.app, "script", {"source": source}, timeout=180)
        rows = {r[0]: r[1] for r in
                ((reply.get("output") or {}).get("script") or [])
                if isinstance(r, list) and len(r) == 2}
        raw = rows.get("output") or ""
        if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
            raw = raw[1:-1]
        return raw

    note("hiding NOW and fronting the Finder")
    request(rig.app, "hide", {"target": "New Old World"})
    time.sleep(1)
    request(rig.app, "front", {"target": "Finder"})
    time.sleep(1)

    desktop = []
    for row in script(
            'tell application "Finder"\nset r to ""\n'
            'repeat with t in (get items of desktop)\n'
            'set q to bounds of t\n'
            'set r to r & (name of t) & "|" & (item 1 of q) & "," & '
            '(item 2 of q) & "," & (item 3 of q) & "," & '
            '(item 4 of q) & ";;"\nend repeat\nreturn r\nend tell'
    ).split(";;"):
        if "|" not in row:
            continue
        name, box = row.split("|", 1)
        try:
            left, top, right, bottom = (int(v) for v in box.split(","))
        except ValueError:
            continue
        desktop.append({"name": name, "bounds": [left, top, right, bottom],
                        "centre": [(left + right) // 2, (top + bottom) // 2]})
    selection_before = script(
        'tell application "Finder" to return (name of items of selection '
        'as string)')

    press = [args.x, args.y]
    if args.pick:
        chosen = [d for d in desktop if d["name"] == args.pick]
        if not chosen:
            raise RuntimeError(
                f"{args.pick!r} is not on this Finder's desktop: "
                + ", ".join(d["name"] for d in desktop))
        press = chosen[0]["centre"]
    if press == [0, 0]:
        raise RuntimeError(
            "no press point: pass --pick <desktop item> or --x/--y. The "
            "desktop holds: " + ", ".join(d["name"] for d in desktop))
    args.x, args.y = press
    note(f"press point {press} (selection before: {selection_before!r})")

    nonce_hi, nonce_lo, epoch = 0x13579BDF, 0x2468ACE0, 1
    rig.app.send({"type": "continuity.arm", "version": CONTINUITY.version,
                  "id": 7101, "nonceHi": nonce_hi, "nonceLo": nonce_lo,
                  "epoch": epoch, "requestedHz": 15, "leaseTicks": 1800})
    # CORRELATED BY ID, never "the last report". The guest arms, and then
    # - with no UDP state yet on the wire - its own five-second arming
    # grace runs out and it reports `exited / lease-expired` on the same
    # lane. A reader taking the LAST report in a ten-second window sees
    # that one and calls a healthy arm a refusal, which cost this
    # instrument its first run.
    arm = None
    deadline = time.monotonic() + args.timeout
    while arm is None and time.monotonic() < deadline:
        rig.pump(0.5)
        arm = next((m for m in rig.app.of_type("continuity.report")
                    if m.get("id") == 7101), None)
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
        udp.sendto(CONTINUITY.encode_state(
            nonce_hi, nonce_lo, epoch, sequence, x, y, button_generation,
            15, int(time.monotonic() * 60) & 0xFFFFFFFF, flags,
            previous_generation, previous_flags), destination)
        rig.pump(0.2, udp=udp)

    # 1. Settle. Whatever the Finder had selected before the gesture,
    #    published by the ordinary poll. This is the generation a press
    #    would have bound under the old ritual.
    state(args.x, args.y, False)
    rig.pump(4.0, udp=udp)
    baseline = rig.app.of_type("continuity.selection")
    baseline_at = time.monotonic()

    # 2. ONE GESTURE: press on the point given and drag away from it, in
    #    steps with dwell — a driven pointer that teleports never starts a
    #    Drag Manager drag at all, which cost an earlier round a false
    #    zero.
    button_generation += 1
    pressed_at = time.monotonic()
    state(args.x, args.y, True)
    for step in range(1, 6):
        state(args.x + args.dx * step // 5, args.y + args.dy * step // 5,
              True)

    # 3. STILL HELD. Everything that arrives in this window arrived while
    #    the person's button was down — which for the resident's frame is
    #    the entire claim being tested.
    rig.pump(args.hold, udp=udp)
    held_until = time.monotonic()
    note("button released next; drag-begin frames so far: "
         + str(len(rig.resident.of_type("continuity.dragBegin"))
               if resident_present else "no resident channel"))
    drag_begins = ([] if not resident_present
                   else rig.resident.of_type("continuity.dragBegin",
                                             since=baseline_at))
    mid_gesture = rig.app.of_type("continuity.selection", since=baseline_at)

    # 4. Release at the press origin, the way the host's cross does. The
    #    release is what ends the Finder's drag loop, so this is the
    #    instant the APPLICATION becomes able to speak at all.
    previous = button_generation
    button_generation += 1
    released_at = time.monotonic()
    state(args.x, args.y, False, previous_generation=previous,
          previous_flags=CONTINUITY.flag_primary_down)
    rig.pump(4.0, udp=udp)
    after_release = rig.app.of_type("continuity.selection", since=baseline_at)

    # 5. THE JOIN, and then the bytes. The generation a grab must name is
    #    the application's; the resident never mints one.
    dragged = [s for s in after_release if s.get("source") == "drag"]
    joined = dragged[-1] if dragged else None
    grab = None
    drained = None
    if joined:
        rig.app.send({"type": "continuity.grab",
                      "version": CONTINUITY.version, "id": 7202,
                      "epoch": epoch, "generation": joined["generation"]})
        rig.pump(args.timeout, udp=udp)
        answers = [m for m in rig.app.messages
                   if m.get("id") == 7202
                   and m.get("type") in ("file.begin", "file.refuse")]
        grab = answers[-1] if answers else None
        if grab and grab.get("type") == "file.begin":
            transfer = grab.get("transfer")
            deadline = time.monotonic() + args.timeout
            while (transfer not in rig.app.bulk_ended
                   and time.monotonic() < deadline):
                rig.pump(0.5, udp=udp)
            body = rig.app.bulk.get(transfer, b"")
            drained = {
                "transfer": transfer,
                "announcedBytes": grab.get("bytes"),
                "drainedBytes": len(body),
                "reachedEnd": transfer in rig.app.bulk_ended,
                "sha256": hashlib.sha256(body).hexdigest(),
                "text": body.decode("mac-roman", "replace")[:120],
            }

    rig.app.send({"type": "continuity.disarm", "version": CONTINUITY.version,
                  "id": 7301, "epoch": epoch, "reason": "disabled"})
    rig.pump(2.0, udp=udp)
    rig.app.send({"type": "bye"})

    def since_press(stamp):
        return None if stamp is None else round(stamp - pressed_at, 3)

    begin = drag_begins[-1] if drag_begins else None
    late_begin = None
    if begin is None and resident_present:
        late = rig.resident.of_type("continuity.dragBegin", since=baseline_at)
        late_begin = late[-1] if late else None

    report = {
        "hellos": rig.hellos,
        "residentChannel": resident_present,
        "pressPoint": [args.x, args.y],
        "desktop": desktop,
        "selectionBeforeTheGesture": selection_before,
        "timeline": {
            "pressedAt": 0.0,
            "heldUntil": since_press(held_until),
            "releasedAt": since_press(released_at),
            "dragBeginArrived": since_press(
                begin["_at"] if begin else
                (late_begin["_at"] if late_begin else None)),
            "applicationDragArrived": since_press(
                joined["_at"] if joined else None),
        },
        "dragBegin": begin or late_begin,
        "baselineSelections": baseline,
        "midGestureSelections": mid_gesture,
        "afterReleaseSelections": after_release,
        "grab": grab,
        "drained": drained,
        "verdict": {
            # The claim, stated as a comparison rather than as a word.
            "residentNamedTheFileWhileHeld": bool(begin),
            "applicationNamedItWhileHeld": bool(
                [s for s in mid_gesture if s.get("source") == "drag"]),
            "joinedOnDragSeq": bool(
                begin and joined
                and begin.get("dragSeq") == joined.get("dragSeq")),
            "sameNameFromBothSenders": bool(
                begin and joined
                and begin.get("item", {}).get("name")
                == (joined.get("item") or {}).get("name")),
            "bytesDrainedWhole": bool(
                drained and drained["reachedEnd"]
                and drained["drainedBytes"] == drained["announcedBytes"]),
        },
    }
    print(json.dumps(report, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - an instrument reports
        print(f"resident drag probe failed: {error}", file=sys.stderr)
        sys.exit(1)
