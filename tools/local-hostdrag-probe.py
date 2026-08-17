#!/usr/bin/env python3
"""Drive `continuity.hostDragBegin` end to end against a booted guest, and
serve the promise it leads to.

    tools/local-hostdrag-probe.py --port <wire port> [--qmp <sock>] \
        [--shots <dir>] [--bytes 614400] [--gesture desktop|window|abort]

THE PROBE IS THE HOST. Slice 1 of the blessed-path drag plan: the guest
no longer waits for an applied button, so nothing about this gesture goes
through the Event Manager. This script publishes a `continuity.offer`,
sends `continuity.hostDragBegin` with the STARTING state, and then does
what the contract says the host does afterwards — nothing but ordinary
Continuity position datagrams, until the receiver asks for the promise
and the guest pulls the bytes back down `continuity.grab`.

WHAT IT SERVES, AND WHY THAT MATTERS. Earlier Python instruments in this
tree publish an offer and never serve the grab, so a drop that COMPLETES
could not be measured by them at all — only a drop that failed early.
This one serves the whole file lane (`file.begin`, bulk frames,
`file.end`), which is what makes the 600 KB gate and the byte-compare
possible without the Swift harness.

THE FIXTURE IS PURE ASCII ON PURPOSE. The byte-compare reads the landed
file back through the guest's own File Manager in chunks, over a wire
that carries MacRoman text; a fixture with high bytes in it would make a
transport question out of a File Manager answer. The pattern is
positional, so a chunk that landed at the wrong offset fails as loudly as
a chunk that arrived wrong.

RECEIPTS GO WHERE YOU POINT --shots, and that must be OUTSIDE
$NOW_SPIN_RUN: `lane-ports reclaim` deletes the run directory, and it has
already eaten one measurement's screendumps.

Not a test and in no gate: it needs a booted guest. scripts/spin-up-ppc
boots one.
"""

import argparse
import hashlib
import json
import os
import select
import socket
import struct
import subprocess
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


def control_frame(payload):
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


def bulk_frame(transfer, payload, last):
    return (struct.pack(">BBHI", BULK, END if last else 0, transfer & 0xFFFF,
                        len(payload)) + payload)


def fixture_bytes(total):
    """A positional ASCII pattern: every 64-byte line names its own offset,
    so a chunk delivered at the wrong place is as visible as one delivered
    wrong."""
    out = bytearray()
    line = 0
    while len(out) < total:
        body = f"{line * 64:010d} ".encode("ascii")
        body += b"." * (63 - len(body)) + b"\n"
        out += body
        line += 1
    return bytes(out[:total])


class Guest:
    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""
        self.seen = []
        self.on_bulk = None
        self._next_id = 7000

    def send(self, obj):
        self.sock.sendall(control_frame(json.dumps(obj).encode()))

    def send_raw(self, data):
        self.sock.sendall(data)

    def _decode(self):
        while len(self.buffer) >= 8:
            _, _, _, length = struct.unpack(">BBHI", self.buffer[:8])
            if len(self.buffer) < 8 + length:
                return None
            channel = self.buffer[0]
            body = self.buffer[8:8 + length]
            self.buffer = self.buffer[8 + length:]
            if channel == BULK:
                if self.on_bulk is not None:
                    self.on_bulk(body)
                continue
            return json.loads(body.decode("utf-8", "replace"))
        return None

    def pump(self, seconds, want_id=None, udp=None, on_message=None):
        """Service the link for `seconds`. Answers pings, records every
        frame, and hands each one to `on_message` — which is how the grab
        is served without a second loop that could miss it."""
        deadline = time.monotonic() + seconds
        answer = None
        while True:
            message = self._decode()
            if message is None:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                watch = [self.sock] + ([udp] if udp is not None else [])
                ready, _, _ = select.select(watch, [], [], remaining)
                if not ready:
                    break
                if udp is not None and udp in ready:
                    try:
                        udp.recvfrom(512)
                    except OSError:
                        pass
                    if self.sock not in ready:
                        continue
                chunk = self.sock.recv(65536)
                if not chunk:
                    raise RuntimeError("guest closed the control connection")
                self.buffer += chunk
                continue
            stamped = dict(message)
            stamped["_at"] = round(time.monotonic(), 3)
            if message.get("type") == "ping":
                self.send({"type": "pong", "id": message.get("id", 0)})
                continue
            self.seen.append(stamped)
            if on_message is not None:
                on_message(message)
            if want_id is not None and message.get("id") == want_id:
                answer = stamped
                if self._decode is None:
                    break
                break
        return answer

    def request(self, name, args=None, line=None):
        self._next_id += 1
        req = {"type": "command.request", "id": self._next_id, "name": name}
        if args:
            req.update(args)
        if line is not None:
            req["line"] = line
        self.send(req)
        return self._next_id

    def ask(self, name, args=None, line=None, timeout=60.0, udp=None,
            on_message=None):
        mid = self.request(name, args=args, line=line)
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            answer = self.pump(0.5, want_id=mid, udp=udp,
                               on_message=on_message)
            if answer is not None:
                return answer
        raise RuntimeError(f"{name} never answered")

    def script(self, source, timeout=240.0, udp=None, on_message=None):
        reply = self.ask("script", {"source": source}, timeout=timeout,
                         udp=udp, on_message=on_message)
        rows = {r[0]: r[1] for r in
                ((reply.get("output") or {}).get("script") or [])
                if isinstance(r, list) and len(r) == 2}
        raw = rows.get("output") or ""
        if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
            raw = raw[1:-1]
        return raw


def tail_pages(guest, max_pages=25, page_lines=40, area="mirror", udp=None):
    """Page backward through the guest's log ring. Walks by row identity
    rather than by the cursor alone — tools/local-drag-log.py's rule, which
    exists because the cursor-only walk returned 46 of 111 rows once."""
    pages, before, seen_keys = [], None, set()
    for _ in range(max_pages):
        args = {"lines": page_lines, "area": area}
        if before is not None:
            args["before"] = int(before)
        reply = guest.ask("tail", args, udp=udp)
        out = (reply.get("output") or {})
        rows = out.get("tail") or []
        if not rows:
            break
        key = (str(rows[0]), str(rows[-1]), len(rows))
        if key in seen_keys:
            break
        seen_keys.add(key)
        pages.append(rows)
        log = {k: v for k, v in (out.get("log") or [])}
        nxt = log.get("next")
        if not nxt:
            break
        before = int(nxt)
    flat = []
    for page in reversed(pages):
        flat.extend(page)
    return flat


def read_gesture(rows, entry, drop, floor, gesture="desktop"):
    """WHAT THE GUEST'S OWN LOG SAYS THE GESTURE WAS — the five readings
    the slice-1 rig could not make.

    That rig verified the promise protocol and the byte path and NOTHING
    about the gesture: it published the drop point and the button-up
    before the guest's service pass ran the held begin, so a TrackDrag
    that returned on its first sample still dropped the file at the
    intended target and the byte-compare passed. `plane=0` was printed in
    every passing receipt and read as noise.

    Each reading is reported with its own evidence line and its own
    verdict, and a MISSING line is reported as missing rather than as a
    failure: absence and defect must not share a word (AGENTS.md).
    """
    import re as _re

    text = [str(r) for r in rows]

    def find(pattern):
        rx = _re.compile(pattern)
        for line in reversed(text):
            m = rx.search(line)
            if m:
                return m, line
        return None, None

    out = {}
    detail, detail_line = find(
        r"drag detail: button level=(\d+) applied=(\d+) toolbox=(\d+) at "
        r"(-?\d+),(-?\d+) setup=(\d+) track=(\d+) ticks")
    inputs, input_line = find(
        r"drag input: calls=(-?\d+) fed=(-?\d+) down=(-?\d+) up=(-?\d+)")
    dropline, drop_line = find(
        r"drag drop: loc='(.{0,4})' err=(-?\d+) end=(-?\d+),(-?\d+)")
    fed, fed_line = find(
        r"drag input: seq (\d+)\.\.(\d+) pt (-?\d+),(-?\d+)\.\."
        r"(-?\d+),(-?\d+)")
    ripe, ripe_line = find(
        r"drag hostDragBegin seq=(\d+) ripened: plane button held after "
        r"(\d+) ticks")
    applied = [line for line in text if "button edge gen=" in line]

    out["trackTicks"] = int(detail.group(7)) if detail else None
    out["levelAtEntry"] = int(detail.group(1)) if detail else None
    out["appliedAtEntry"] = int(detail.group(2)) if detail else None
    out["entryLogged"] = ([int(detail.group(4)), int(detail.group(5))]
                          if detail else None)
    out["inputDowns"] = int(inputs.group(3)) if inputs else None
    out["inputUps"] = int(inputs.group(4)) if inputs else None
    out["inputCalls"] = int(inputs.group(1)) if inputs else None
    # WHAT THE MANAGER WAS FED, which is what it resolves the drop
    # against. `end=` on the drop line is GetMouse — the SPRITE — and
    # reading one as the other is how round 1 of this branch reported a
    # correct drop as a failure.
    out["firstFedPoint"] = ([int(fed.group(3)), int(fed.group(4))]
                            if fed else None)
    out["lastFedPoint"] = ([int(fed.group(5)), int(fed.group(6))]
                           if fed else None)
    out["cursorSpriteAtEnd"] = ([int(dropline.group(3)),
                                 int(dropline.group(4))]
                                if dropline else None)
    out["dropLoc"] = dropline.group(1) if dropline else None
    out["ripenTicks"] = int(ripe.group(2)) if ripe else None
    out["appliedButtonEdges"] = len(applied)
    out["evidence"] = [line for line in
                       (detail_line, input_line, drop_line, ripe_line)
                       if line]

    def verdict(value, ok, why):
        return {"value": value,
                "verdict": "absent" if value is None else
                           ("pass" if ok else "FAIL"),
                "why": why}

    end = out["lastFedPoint"]
    began = out["firstFedPoint"]
    checks = {
        "trackRanForAGesture": verdict(
            out["trackTicks"],
            out["trackTicks"] is not None and out["trackTicks"] >= floor,
            f"TrackDrag must have run >= {floor} ticks; one tick is the "
            "instant drop this fix is about"),
        "levelHeldAtEntry": verdict(
            out["levelAtEntry"], out["levelAtEntry"] == 1,
            "the cursor plane's button must read DOWN as TrackDrag is "
            "entered — level=0 there is the instant drop itself"),
        "inputProcSawTheButtonDown": verdict(
            out["inputDowns"],
            out["inputDowns"] is not None and out["inputDowns"] > 0,
            "the Manager must have sampled a held button through our proc"),
        # An abort has no drop by design — the Manager returns
        # userCanceledErr and plays its own snap-back — so it is asked the
        # question it HAS: did the gesture end where the pointer was
        # driven, having travelled there first.
        "droppedAtTheRelease": verdict(
            end,
            end is not None and began is not None
            and abs(end[0] - drop[0]) <= 8 and abs(end[1] - drop[1]) <= 8
            and abs(began[0] - entry[0]) <= 12
            and abs(began[1] - entry[1]) <= 12
            and (abs(end[0] - entry[0]) > 8 or abs(end[1] - entry[1]) > 8),
            ("the gesture must end where the button was released, away "
             "from the entry point" if gesture == "abort" else
             "the drop must land where the button was released, at a point "
             "published AFTER the begin and away from the entry point")),
        "residentAppliedNoButton": verdict(
            out["appliedButtonEdges"],
            out["appliedButtonEdges"] == 0 and out["appliedAtEntry"] == 0,
            "a carried level must advance no generation, so the resident "
            "applies nothing and D5 survives the fix"),
        "beginRipenedOnTheLevel": verdict(
            out["ripenTicks"], out["ripenTicks"] is not None,
            "the guest must have gated its begin on the plane's level"),
    }
    out["checks"] = checks
    out["passed"] = all(c["verdict"] == "pass" for c in checks.values())
    return out


class Shots:
    """QMP screendumps: the guest's screen from OUTSIDE the guest. The
    `screenshot` verb travels the wire under measurement; QMP does not."""

    def __init__(self, qmp, directory, lab_root):
        self.qmp = qmp
        self.dir = directory
        self.tool = os.path.join(lab_root, "tools", "qmp") if lab_root else None
        self.taken = []
        if directory:
            os.makedirs(directory, exist_ok=True)

    def take(self, name):
        if not (self.qmp and self.dir and self.tool
                and os.path.exists(self.tool)):
            return None
        path = os.path.join(self.dir, f"{name}.ppm")
        try:
            subprocess.run([self.tool, self.qmp, "screendump",
                            json.dumps({"filename": path})],
                           check=True, capture_output=True, timeout=30)
        except Exception as error:  # noqa: BLE001 - an instrument reports
            print(f"[probe] screendump {name} failed: {error}",
                  file=sys.stderr, flush=True)
            return None
        png = path[:-4] + ".png"
        try:
            subprocess.run(["sips", "-s", "format", "png", path, "--out", png],
                           check=True, capture_output=True, timeout=60)
            os.remove(path)
            path = png
        except Exception:  # noqa: BLE001 - the ppm is still evidence
            pass
        self.taken.append(path)
        return path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--host", default="0.0.0.0")
    ap.add_argument("--udp-host", default=None)
    ap.add_argument("--epoch", type=int, default=4401)
    ap.add_argument("--name", default=None,
                    help="the fixture's name on the guest; defaults to a "
                         "run-unique one so a rerun is not a collision test "
                         "by accident")
    ap.add_argument("--bytes", type=int, default=4096)
    ap.add_argument("--start-x", type=int, default=300)
    ap.add_argument("--start-y", type=int, default=200)
    ap.add_argument("--drop-x", type=int, default=120)
    ap.add_argument("--drop-y", type=int, default=380)
    ap.add_argument("--gesture", default="desktop",
                    choices=["desktop", "window", "abort", "collision"],
                    help="desktop: drop on exposed desktop. window: open a "
                         "Finder window first and drop into it. abort: drive "
                         "to a point no target accepts, then release. "
                         "collision: two drops of the same name.")
    ap.add_argument("--keep-now-visible", action="store_true",
                    help="do NOT hide NOW's own window. The default hides "
                         "it, because a window of ours over the drop point "
                         "measures our own window, not the Finder.")
    ap.add_argument("--front", default="Finder",
                    choices=["Finder", "New Old World", "none"],
                    help="which process to leave frontmost. The background "
                         "TrackDrag question is answered by leaving this at "
                         "Finder and reading the guest's own `drag begin: "
                         "... front=` line.")
    ap.add_argument("--qmp", default=None)
    ap.add_argument("--shots", default=None)
    ap.add_argument("--lab-root", default=os.environ.get("NOW_LAB_ROOT", ""))
    ap.add_argument("--require-build", default=None)
    ap.add_argument("--wait", type=float, default=300)
    ap.add_argument("--timeout", type=float, default=20)
    ap.add_argument("--hold", type=float, default=3.0)
    ap.add_argument("--button-edges", action="store_true",
                    help="drive the button as generation EDGES, the way "
                         "this rig did before 2026-08-17. The product "
                         "holds a level with no generation behind it; this "
                         "reproduces the older shape, in which the "
                         "resident applies a real press and the rig cannot "
                         "see an instant drop.")
    ap.add_argument("--track-floor", type=int, default=30,
                    help="ticks TrackDrag must have run for the gesture to "
                         "have been a gesture rather than an instant drop")
    ap.add_argument("--verify", action="store_true",
                    help="read the landed file back through the guest's own "
                         "File Manager and compare it whole")
    args = ap.parse_args()

    stamp = int(time.time()) % 100000
    fixture_name = args.name or f"HostDrag{stamp}.txt"
    payload = fixture_bytes(args.bytes)
    digest = hashlib.sha256(payload).hexdigest()

    shots = Shots(args.qmp, args.shots, args.lab_root)

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)
    server.settimeout(args.wait)
    print(f"[probe] listening on {args.host}:{args.port}", flush=True)
    control, tcp_peer = server.accept()
    control.settimeout(args.timeout)
    guest = Guest(control)
    hello = guest._decode()
    while hello is None:
        guest.buffer += control.recv(65536)
        hello = guest._decode()
    guest.send({"type": "hello", "contract": CONTRACT, "side": "host",
                "version": "0", "name": "local-hostdrag-probe",
                "chunk": 4096})
    print("[probe] guest hello:", json.dumps(hello), flush=True)
    if args.require_build and args.require_build not in json.dumps(hello):
        raise RuntimeError(
            "this is not the build under test: the guest's hello does not "
            f"name {args.require_build!r}. Every QEMU guest on this Mac dials "
            "10.0.2.2, so another lane's VM can answer here.")

    # ---- serving the promise ------------------------------------------
    # The guest sends continuity.grab from INSIDE the receiver's drop. It
    # is served here, from the same loop that is driving the pointer,
    # because there is no other loop: the whole point of the lane is that
    # the guest is blocked while this happens.
    served = {"grabs": [], "sent": 0}
    # THE LANDED FILE, COMING BACK THE OTHER WAY. `read file` through the
    # script verb truncates at ~1 KB, so a chunked read is 600 requests
    # for a 600 KB file and proves the transport as much as the file. The
    # guest's own `put` verb hands the whole thing back down the ordinary
    # send lane instead, and the compare is then a sha256 of bytes that
    # never went through a text encoding.
    back = {"active": False, "id": None, "bytes": bytearray(),
            "announced": None, "done": None}

    def serve(message):
        kind = message.get("type")
        if kind == "file.offer":
            back["active"] = True
            back["id"] = message.get("id")
            back["announced"] = message.get("bytes")
            back["bytes"] = bytearray()
            guest.send({"type": "file.accept", "id": message.get("id"),
                        "have": 0})
            return
        if kind == "file.begin" and back["active"]:
            return
        if kind == "file.end" and back["active"]:
            back["done"] = dict(message)
            back["active"] = False
            guest.send({"type": "file.done", "id": message.get("id"),
                        "ok": True})
            return
        if kind == "file.refuse":
            back["done"] = dict(message)
            back["active"] = False
            return
        if kind != "continuity.grab":
            return
        transfer = int(message.get("id") or 0)
        served["grabs"].append(dict(message))
        print(f"[probe] serving continuity.grab id={transfer} "
              f"{len(payload)} bytes", flush=True)
        guest.send({"type": "file.begin", "id": transfer,
                    "name": fixture_name, "bytes": len(payload),
                    "fileType": "TEXT", "creator": "ttxt"})
        offset = 0
        while offset < len(payload):
            chunk = payload[offset:offset + 4096]
            offset += len(chunk)
            guest.send_raw(bulk_frame(transfer, chunk,
                                      offset >= len(payload)))
        served["sent"] += len(payload)
        guest.send({"type": "file.end", "id": transfer, "ok": True})

    # ---- the rig ------------------------------------------------------
    # NOW's own window over the drop point measures NOW's own window. The
    # 2026-08-17 run logged the occlusion instead of removing it; removing
    # it is one verb.
    if not args.keep_now_visible:
        guest.ask("hide", {"target": "New Old World"}, on_message=serve)
        time.sleep(1)
    if args.front != "none":
        guest.ask("front", {"target": args.front}, on_message=serve)
        time.sleep(1)

    window_bounds = None
    if args.gesture == "window":
        guest.script('tell application "Finder"\nactivate\n'
                     'open startup disk\nend tell', on_message=serve)
        time.sleep(2)
        # ONE PHRASING THAT ANSWERS, and it is the desktop listing's:
        # `(bounds of front window) as string` errors -1753 on this
        # AppleScript, and slice 0's fallback parser then read
        # `timeoutMs 15000` as a window rectangle. Building the string
        # item by item is the form the Finder actually answers.
        raw = guest.script(
            'tell application "Finder"\nset q to bounds of front window\n'
            'return ((item 1 of q) & "," & (item 2 of q) & "," & '
            '(item 3 of q) & "," & (item 4 of q)) as string\nend tell',
            on_message=serve)
        nums = [int(n) for n in raw.replace(",", " ").split() if
                n.lstrip("-").isdigit()]
        if len(nums) != 4:
            raise RuntimeError(
                "the Finder's front window has no readable bounds "
                f"({raw!r}); refusing to drop at a guessed point - that is "
                "how slice 0 aimed a gesture at timeoutMs")
        if len(nums) == 4:
            window_bounds = nums
            args.drop_x = (nums[0] + nums[2]) // 2
            args.drop_y = (nums[1] + nums[3]) // 2 + 20
            print(f"[probe] Finder window {nums}, dropping at "
                  f"{args.drop_x},{args.drop_y}", flush=True)

    before = guest.script(
        'tell application "Finder" to return (count of (every file of '
        f'desktop whose name contains "{fixture_name[:-4]}")) as string',
        on_message=serve)

    # ---- arm the plane -------------------------------------------------
    nonce_hi, nonce_lo = 0x484F5354, 0x44524147
    rounds = 2 if args.gesture == "collision" else 1
    results = []

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind(("0.0.0.0", 0))

    for attempt in range(rounds):
        # A FRESH EPOCH PER GESTURE. Slice 0 paid for this: a long
        # TrackDrag leaves the plane's button edge stuck, and every
        # gesture after the first reported `button-never-came` — a stuck
        # plane and a refused drag wearing one word.
        epoch = args.epoch + attempt
        guest.send({"type": "continuity.arm", "version": CONTINUITY.version,
                    "id": 7101 + attempt, "nonceHi": nonce_hi,
                    "nonceLo": nonce_lo, "epoch": epoch,
                    "requestedHz": 30, "leaseTicks": 3600})
        arm = guest.pump(args.timeout, want_id=7101 + attempt, udp=udp,
                         on_message=serve)
        if not arm or arm.get("state") != "armed" or not arm.get("udpPort"):
            raise RuntimeError("guest refused Continuity: " + json.dumps(arm))
        destination = (args.udp_host or tcp_peer[0], int(arm["udpPort"]))

        state = {"sequence": 0, "generation": 0}

        def send_state(h, v, down):
            state["sequence"] += 1
            flags = CONTINUITY.flag_inside
            if down:
                flags |= CONTINUITY.flag_primary_down
            udp.sendto(CONTINUITY.encode_state(
                nonce_hi, nonce_lo, epoch, state["sequence"], h, v,
                state["generation"], 30,
                int(time.monotonic() * 60) & 0xFFFFFFFF, flags), destination)

        # Settle, button up, at the point the crossing will start from.
        for _ in range(10):
            send_state(args.start_x, args.start_y, False)
            guest.pump(0.03, udp=udp, on_message=serve)

        item = {"name": fixture_name, "fileType": "TEXT", "creator": "ttxt",
                "dataSize": len(payload), "isFolder": False}
        guest.send({"type": "continuity.offer", "version": CONTINUITY.version,
                    "epoch": epoch, "generation": 1, "item": item})
        guest.pump(0.5, udp=udp, on_message=serve)

        # THE BUTTON IS A LEVEL, NOT AN EDGE, AND THAT IS THE PRODUCT
        # SEQUENCING. The host holds `.primaryDown` in the plane for the
        # life of a staged carry WITHOUT advancing buttonGeneration, so
        # the guest's resident applies nothing (it acts only on a newer
        # generation) while the drag's input proc reads a held button.
        # Bumping the generation here is what made this rig disagree with
        # the product: the resident applied a real press, and the
        # release-at-the-target that followed was applied before the
        # guest's service pass had run the held begin — so an instantly
        # returning TrackDrag produced a drop at the intended target and
        # every assertion passed (F2, "the rig blind spot"). `--button-
        # edges` restores that older shape for comparison, and is not the
        # product.
        if args.button_edges:
            state["generation"] += 1
        for _ in range(20):
            send_state(args.start_x, args.start_y, True)
            guest.pump(0.02, udp=udp, on_message=serve)

        shots.take(f"r{attempt}-00-before")
        guest.send({"type": "continuity.hostDragBegin",
                    "version": CONTINUITY.version, "epoch": epoch,
                    "dragSeq": 1000 + attempt,
                    "pos": {"h": args.start_x, "v": args.start_y},
                    "item": {k: v for k, v in item.items()
                             if k != "isFolder"}})
        print(f"[probe] hostDragBegin sent, seq={1000 + attempt}", flush=True)

        # From here the host does nothing but report the pointer, which is
        # the contract's whole claim about this lane.
        drop_x = args.drop_x
        drop_y = args.drop_y
        if args.gesture == "abort":
            # A point no target accepts: off the bottom of any window and
            # any desktop icon, then button-up. The Manager's own
            # userCanceledErr, no cancel channel of ours.
            drop_x, drop_y = 2, 2
        for step in range(1, 41):
            h = args.start_x + (drop_x - args.start_x) * step // 40
            v = args.start_y + (drop_y - args.start_y) * step // 40
            send_state(h, v, True)
            guest.pump(0.03, udp=udp, on_message=serve)
        shots.take(f"r{attempt}-01-mid")
        held_until = time.monotonic() + args.hold
        while time.monotonic() < held_until:
            send_state(drop_x, drop_y, True)
            guest.pump(0.05, udp=udp, on_message=serve)
        shots.take(f"r{attempt}-02-held")

        # And the release is a cleared LEVEL for the same reason: over
        # there it is the input proc's next sample, which is what ends
        # TrackDrag where the person let go.
        if args.button_edges:
            state["generation"] += 1
        for _ in range(25):
            send_state(drop_x, drop_y, False)
            guest.pump(0.04, udp=udp, on_message=serve)
        print("[probe] released", flush=True)
        # The pull happens inside the drop, so the wire has to be serviced
        # generously here — this is where the 600 KB gate is won or lost.
        guest.pump(90.0, udp=udp, on_message=serve)
        shots.take(f"r{attempt}-03-after")

        report = guest.ask("offer", timeout=60, udp=udp, on_message=serve)
        rows = tail_pages(guest, udp=udp)
        results.append({"epoch": epoch, "report": report,
                        "gesture": read_gesture(
                            rows, [args.start_x, args.start_y],
                            [drop_x, drop_y], args.track_floor,
                            args.gesture),
                        "logRows": rows[-160:]})
        guest.send({"type": "continuity.disarm",
                    "version": CONTINUITY.version, "id": 7301 + attempt,
                    "epoch": epoch, "reason": "disabled"})
        guest.pump(args.timeout, want_id=7301 + attempt, udp=udp,
                   on_message=serve)

    after = guest.script(
        'tell application "Finder" to return (count of (every file of '
        f'desktop whose name contains "{fixture_name[:-4]}")) as string',
        on_message=serve)

    # ---- the byte-compare, whole ------------------------------------
    # Read back through the guest's own File Manager, every byte, and
    # compared against what the host sent. In 1000-byte chunks because
    # the script verb's reply truncates at 1024 and says so — a chunk
    # that came back short would otherwise be a silent hole in the middle
    # of a "identical: true".
    #
    # The `put` verb would hand the whole file back in one transfer and
    # was tried first: its console parser takes ONE whitespace token as
    # the path, so no file under "Macintosh HD:Desktop Folder:" is
    # reachable by it. Recorded rather than worked around, because it is
    # a real gap in a verb whose whole subject is full HFS paths.
    verify = None
    if args.verify:
        # WHERE THE RECEIVER PUT IT, not where we assume. A window drop
        # lands in that window's folder; the desktop drop lands on the
        # desktop. Reading back from the wrong one reports a missing file
        # for a drag that worked.
        path = (f"Macintosh HD:{fixture_name}" if args.gesture == "window"
                else f"Macintosh HD:Desktop Folder:{fixture_name}")
        size_raw = guest.script(
            f'tell application "Finder" to get size of file "{path}"',
            on_message=serve)
        landed = bytearray()
        offset = 0
        trouble = None
        while offset < len(payload) and trouble is None:
            span = min(1000, len(payload) - offset)
            reply = guest.ask("script", {
                "source": f'return (read file "{path}" from {offset + 1} '
                          f'to {offset + span})'}, timeout=180,
                on_message=serve)
            rows = {r[0]: r[1] for r in
                    ((reply.get("output") or {}).get("script") or [])
                    if isinstance(r, list) and len(r) == 2}
            if str(rows.get("osaErr")) not in ("0",):
                trouble = f"osaErr {rows.get('osaErr')} at {offset}"
                break
            if str(rows.get("truncated")) == "true":
                trouble = f"reply truncated at {offset}"
                break
            raw = rows.get("output") or ""
            if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
                raw = raw[1:-1]
            landed.extend(raw.encode("ascii", "replace"))
            offset += span
        landed = bytes(landed)
        mismatch = None
        if landed != payload:
            for i, (a, b) in enumerate(zip(landed, payload)):
                if a != b:
                    mismatch = i
                    break
            if mismatch is None:
                mismatch = min(len(landed), len(payload))
        verify = {"path": path,
                  "finderSize": size_raw,
                  "bytesReadBack": len(landed),
                  "bytesExpected": len(payload),
                  "sha256Expected": digest,
                  "sha256ReadBack": hashlib.sha256(landed).hexdigest(),
                  "identical": landed == payload,
                  "firstDifferingOffset": mismatch,
                  "trouble": trouble}

    guest.send({"type": "bye"})

    print(json.dumps({
        "guest": hello,
        "fixture": {"name": fixture_name, "bytes": len(payload),
                    "sha256": digest},
        "gesture": args.gesture,
        "start": [args.start_x, args.start_y],
        "drop": [args.drop_x, args.drop_y],
        "finderWindow": window_bounds,
        "desktopCountBefore": before,
        "desktopCountAfter": after,
        "served": {"grabs": served["grabs"], "bytesSent": served["sent"]},
        "buttonMode": "edges" if args.button_edges else "level",
        "gestureChecksPassed": all(r["gesture"]["passed"] for r in results),
        "rounds": results,
        "verify": verify,
        "screendumps": shots.taken,
    }, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:  # noqa: BLE001 - an instrument reports
        print(f"local-hostdrag-probe failed: {error}", file=sys.stderr)
        sys.exit(1)
