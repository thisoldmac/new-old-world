#!/usr/bin/env python3
"""What did the press DO? — the Finder's own testimony, beside the plane's.

    tools/local-drag-source.py --port 17705 --expect-build cfc5c1a1

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody.

WHY IT EXISTS. The tracking-handler route reached its last unknown on
2026-08-16: with the Finder brought front, the handler REGISTERS in the
Finder's own context under a bare Continuity arm (`reg app=Finder err=0`)
and is then never called (`calls=0`). Both selection generations came
back empty. So the drag never began — and nothing in that round could say
whether the press had missed the icon, been delivered to the wrong
application, or landed correctly on an icon the Finder simply declined to
drag. Those are three different defects with one silence.

THE ORACLE IS THE FINDER, NOT OUR ARITHMETIC. `bounds of` and
`selection`, asked of the Finder before and after the gesture, separate
them in one run:

  * selection empty and bounds unmoved  -> THE PRESS MISSED, or never
    reached the Finder's stream at all;
  * selection names the item, bounds unmoved -> the press landed and
    SELECTED, and the motion profile did not become a drag;
  * bounds moved -> the Finder dragged, and `calls` says whether the
    plane saw it.

That third row is the one the acceptance needs, and it is the row this
instrument exists to reach.

TWO PRECONDITIONS IT ASSERTS RATHER THAN ASSUMES, both already paid for
by sibling instruments on this desk:

  1. THE FINDER MUST BE FRONT. Under cooperative scheduling a background
     Finder with NOW frontmost and driving at 60 Hz never pumps, and a
     plane that can only register from a pass cannot register from a
     process that never runs (docs/open-issues.md, 2026-08-16). A person
     dragging a file out of a Finder window has the Finder front by the
     act of pointing at it, so this is a rig requirement and not a
     product constraint — but a rig that skips it measures a plane that
     registers nowhere and reads exactly like a dead resident.
  2. NOW MUST BE HIDDEN. Its window lies over the desktop until it is
     hidden, and a press that lands on it is a press on the wrong
     application. `hide` rather than a second `front`: fronting reorders,
     hiding exposes (tools/local-finder-drag.py earned that sentence).

WHAT IT DRAGS is a desktop icon to a checked-empty spot on the same
desktop — a rearrangement, the ordinary Mac icon shuffle. The destination
is checked against every item and every open window the Finder reports,
and against a minimum travel, by tools/local_finder_geometry.py. Nothing
is filed anywhere and this will not drop an icon ON something.

It refuses a guest whose hello build is not `--expect-build`: every QEMU
guest on this Mac sees the host as 10.0.2.2 and any session's VM can
answer this listener (AGENTS.md).
"""

import argparse
import json
import os
import select
import socket
import sys
import time
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
# APPENDED, never inserted at the front — there are two modules named
# `nowwire` in this tree and only scripts/probes/ has GuestLink. See
# tools/local-finder-drag.py for the symptom this produces.
sys.path.append(os.path.dirname(os.path.abspath(__file__)))
import nowwire  # noqa: E402

from continuity_contract import load as load_continuity_contract  # noqa: E402
from local_finder_geometry import (clear_spot, desktop_items,  # noqa: E402
                                   finder_psn, finder_windows, script)

CONTINUITY = load_continuity_contract(Path(ROOT))


def finder_selection(link):
    """What the Finder says is selected, in its own words.

    The half the previous round could not ask. `selection` of the Finder
    is a list, so an empty answer and a named answer are different
    strings rather than two readings of one silence."""
    return script(link,
                  'tell application "Finder"\nset r to ""\n'
                  'repeat with t in (get selection)\n'
                  'set r to r & (name of t) & ";;"\nend repeat\n'
                  'return r\nend tell').strip()


def drag_lines(link, pages=30, keep=None):
    """The resident's own drag rows, PAGED back through the log ring.

    Paging is not a nicety here. The targeting stream is always on and a
    single gesture writes tens of thousands of `drag track` rows, so the
    one line the acceptance is owed — `drag bind … latency=N ticks`,
    written once per drag — is dozens of pages behind the newest entry by
    the time anything can ask. A single 40-line tail reads the end of the
    flood and reports the absence of a line it never looked for.

    `keep` filters as it walks, so the interesting rows survive a ring
    that the tracks would otherwise push them out of.
    """
    out = []
    before = None
    for _ in range(pages):
        args = {"lines": 40, "area": "mirror"}
        if before is not None:
            args["before"] = before
        page = link.command("tail", args, timeout=60)
        rows = [r[1] for r in (page.get("tail") or [])
                if isinstance(r, list) and len(r) == 2]
        out = [r for r in rows
               if "drag" in r and (keep is None or any(k in r for k in keep))
               ] + out
        cursor = None
        for r in (page.get("log") or []):
            if isinstance(r, list) and len(r) == 2 and r[0] == "next":
                cursor = r[1]
        if cursor is None:
            break
        try:
            before = int(str(cursor).split()[0])
        except ValueError:
            break
    return out


class Plane:
    """The Continuity state plane, driven over UDP beside the wire.

    A thin thing on purpose: the wire link is nowwire's, so console verbs
    and unsolicited continuity.selection frames come off the same reader
    and cannot be lost to a second socket nobody is draining."""

    def __init__(self, link, peer_host):
        self.link = link
        self.nonce_hi, self.nonce_lo, self.epoch = 0x13579BDF, 0x2468ACE0, 1
        self.sequence = 0
        self.button_generation = 0
        arm_id = 7101
        link._send({"type": "continuity.arm", "id": arm_id,
                    "version": CONTINUITY.version, "nonceHi": self.nonce_hi,
                    "nonceLo": self.nonce_lo, "epoch": self.epoch,
                    "requestedHz": 15, "leaseTicks": 1800})
        self.arm = self.await_type("continuity.report", 15)
        if not self.arm or self.arm.get("state") != "armed":
            raise RuntimeError("guest refused Continuity: "
                               + json.dumps(self.arm))
        self.udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.udp.bind(("0.0.0.0", 0))
        self.destination = (peer_host, int(self.arm["udpPort"]))

    def await_type(self, kind, seconds):
        deadline = time.time() + seconds
        while time.time() < deadline:
            try:
                msg = link_next(self.link, deadline - time.time())
            except TimeoutError:
                return None
            if msg.get("type") == kind:
                return msg
        return None

    def state(self, x, y, down, previous_generation=0, previous_flags=0):
        self.sequence += 1
        flags = CONTINUITY.flag_inside
        if down:
            flags |= CONTINUITY.flag_primary_down
        self.udp.sendto(CONTINUITY.encode_state(
            self.nonce_hi, self.nonce_lo, self.epoch, self.sequence, x, y,
            self.button_generation, 15,
            int(time.monotonic() * 60) & 0xFFFFFFFF, flags,
            previous_generation, previous_flags), self.destination)

    def settle(self, seconds):
        """Read both sockets for a while. The guest's UDP acknowledgements
        MUST be drained: leaving them unread cost the sibling instrument
        three runs that reported an absence while the guest's own report
        said `acceptedPackets: 0`."""
        deadline = time.time() + seconds
        while time.time() < deadline:
            ready, _, _ = select.select(
                [self.link.sock, self.udp], [], [],
                max(0.0, min(0.25, deadline - time.time())))
            if self.udp in ready:
                try:
                    self.udp.recvfrom(256)
                except OSError:
                    pass
            if self.link.sock in ready:
                try:
                    link_next(self.link, 0.25)
                except TimeoutError:
                    pass

    def disarm(self):
        self.link._send({"type": "continuity.disarm", "id": 7301,
                         "version": CONTINUITY.version, "epoch": self.epoch,
                         "reason": "disabled"})
        self.settle(2.0)


def link_next(link, timeout):
    """One message off the wire, servicing ping, keeping the unsolicited."""
    deadline = time.time() + max(0.0, timeout)
    return link._pump(None, deadline)


def selections(link, since_index=0):
    return [m for m in link._unsolicited[since_index:]
            if m.get("type") == "continuity.selection"]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=int, default=240)
    ap.add_argument("--expect-build", default=None)
    ap.add_argument("--item", default=None)
    ap.add_argument("--steps", type=int, default=12,
                    help="motion steps between press and release")
    ap.add_argument("--dwell", type=float, default=0.12,
                    help="seconds between motion steps — the shape a hand "
                         "makes, rather than a teleport")
    ap.add_argument("--hold", type=float, default=6.0,
                    help="seconds to keep the button down after the motion")
    ap.add_argument("--front-finder", dest="front", action="store_true",
                    default=True)
    ap.add_argument("--no-front-finder", dest="front", action="store_false",
                    help="the previous round's shape: arm and drive without "
                         "fronting the target, which measures a plane that "
                         "registers nowhere")
    ap.add_argument("--hide-now", dest="hide", action="store_true",
                    default=True)
    ap.add_argument("--no-hide-now", dest="hide", action="store_false")
    ap.add_argument("--json", default=None, help="write the record here")
    a = ap.parse_args()

    link = nowwire.GuestLink.await_guest(a.port, timeout=a.wait)
    peer = link.sock.getpeername()[0]
    build = str(link.hello.get("build") or "")
    if a.expect_build and a.expect_build not in build:
        raise SystemExit(
            f"WRONG BUILD: wanted {a.expect_build!r}, this guest says "
            f"{build!r}. Every QEMU guest on this Mac dials 10.0.2.2.")
    print(f"guest build: {build}")
    ext = (link.command("mirror", timeout=60).get("mirror") or {}) \
        .get("extension") or {}
    print(f"resident {ext.get('lifecycle')} caps={ext.get('capabilities')}")

    print("\n== 1. the preconditions, asserted rather than assumed ==")
    if a.hide:
        link.command("hide", {"target": "New Old World"}, timeout=60)
        time.sleep(1)
    if a.front:
        link.command("front", {"target": "Finder"}, timeout=60)
        time.sleep(1)
    print(f"   NOW hidden: {a.hide}     Finder fronted: {a.front}")

    items = desktop_items(link)
    psn = finder_psn(link)
    if psn is None:
        print("  INCONCLUSIVE: no Finder in the scene's process roster.")
        return 2
    wins = finder_windows(link, psn)
    desktop = next((w for w in wins if w.get("title") == "Desktop"), None)
    if desktop is None:
        print("  INCONCLUSIVE: the guest's walk reports no Desktop window.")
        return 2
    b = desktop["bounds"]
    frame = {"l": b["left"], "t": b["top"], "r": b["right"],
             "b": b["bottom"]}
    obstacles = []
    for w in wins:
        if w is desktop:
            continue
        wb = w.get("bounds") or {}
        if wb:
            obstacles.append({"l": wb["left"] - 8, "t": wb["top"] - 28,
                              "r": wb["right"] + 8, "b": wb["bottom"] + 8})

    subject = next((it for it in items if it["name"].endswith(".txt")),
                   items[0] if items else None)
    if a.item:
        subject = next((it for it in items if it["name"] == a.item), None)
    if subject is None:
        print("  INCONCLUSIVE: nothing on this desktop to pick up.")
        return 2
    spot = clear_spot(items, subject, subject["r"] - subject["l"],
                      subject["b"] - subject["t"], frame, obstacles)
    if spot is None:
        print("  INCONCLUSIVE: no empty spot far enough from the subject. "
              "Refusing to aim a drag at nothing.")
        return 2
    start = ((subject["l"] + subject["r"]) // 2,
             (subject["t"] + subject["b"]) // 2)
    end = ((spot[0] + spot[2]) // 2, (spot[1] + spot[3]) // 2)
    before_sel = finder_selection(link)
    print(f"   subject {subject['name']!r} at "
          f"({subject['l']},{subject['t']})  ->  aiming at "
          f"({spot[0]},{spot[1]})")
    print(f"   the Finder's selection before anything: {before_sel!r}")

    print("\n== 2. a bare Continuity arm, and the gesture ==")
    plane = Plane(link, peer)
    print(f"   armed: udpPort={plane.arm.get('udpPort')} "
          f"state={plane.arm.get('state')}")
    mark = len(link._unsolicited)
    plane.state(start[0], start[1], False)
    plane.settle(3.0)
    baseline = selections(link, mark)
    mark = len(link._unsolicited)

    # THE PRESS, on the point the Finder itself named, and then motion in
    # SMALL STEPS WITH DWELL. The previous round sent five packets back to
    # back; a Finder drag is begun by motion the application observes
    # while the button is down, and a hand does not teleport.
    plane.button_generation += 1
    plane.state(start[0], start[1], True)
    plane.settle(0.4)
    for step in range(1, a.steps + 1):
        plane.state(start[0] + (end[0] - start[0]) * step // a.steps,
                    start[1] + (end[1] - start[1]) * step // a.steps, True)
        plane.settle(a.dwell)
    plane.settle(a.hold)
    mid = selections(link, mark)

    previous = plane.button_generation
    plane.button_generation += 1
    plane.state(end[0], end[1], False, previous_generation=previous,
                previous_flags=CONTINUITY.flag_primary_down)
    plane.settle(4.0)
    after = selections(link, mark)

    print("\n== 3. THE ORACLE: what the Finder says the press did ==")
    now = {it["name"]: it for it in desktop_items(link)}.get(subject["name"])
    after_sel = finder_selection(link)
    moved = bool(now and (now["l"], now["t"]) != (subject["l"], subject["t"]))
    selected = subject["name"] in after_sel
    print(f"   bounds  before ({subject['l']},{subject['t']})  "
          f"after ({now['l'] if now else '?'},{now['t'] if now else '?'})"
          f"   aimed at ({spot[0]},{spot[1]})")
    print(f"   the Finder's selection after: {after_sel!r}")

    print("\n== 4. what the plane saw ==")
    rows = drag_lines(link, keep=("drag bind", "drag handler", "drag begin",
                                  "drag item", "drag end", "drag obs"))
    for row in rows:
        print("   " + row)
    latency = next((r for r in rows if "drag bind" in r), None)

    print("\n== 5. THE INVERSION: a stale cache against a fresh drag ==")
    # The wrong-file case, asked of the guest directly. `stale` is the
    # generation the person had selected BEFORE the gesture — the one a
    # cache would have bound — and `fresh` is the drag. A grab for each
    # says what this guest will actually serve, which is the only account
    # that matters; the host's decision table is unit-tested without a
    # Macintosh and this is the other half.
    grabs = []
    stale = baseline[-1]["generation"] if baseline else None
    drag_gen = next((m.get("generation") for m in reversed(after)
                     if m.get("source") == "drag"), None)
    for label, generation in (("stale selection", stale), ("the drag",
                                                           drag_gen)):
        if generation is None:
            continue
        gid = 7200 + len(grabs)
        link._send({"type": "continuity.grab", "id": gid,
                    "version": CONTINUITY.version, "epoch": plane.epoch,
                    "generation": generation})
        plane.settle(6.0)
        reply = next((m for m in link._unsolicited if m.get("id") == gid),
                     None)
        served = None
        for m in link._unsolicited:
            if m.get("type") in ("file.begin", "continuity.report") \
                    and m.get("id") == gid:
                served = m
        grabs.append({"label": label, "generation": generation,
                      "reply": reply, "served": served})
        print(f"   grab {label} (generation {generation}) -> "
              f"{json.dumps(reply) if reply else 'no reply on the lane'}")

    print("\n== 6. the verdict ==")
    if moved:
        print("   THE FINDER DRAGGED IT. The Continuity-driven gesture is a "
              "real drag by the Finder's own account.")
    elif selected:
        print("   SELECTED, NOT DRAGGED. The press landed on the icon and "
              "the Finder took it as a click. The motion profile is the "
              "variable, not the press.")
    else:
        print("   THE PRESS DID NOTHING THE FINDER WILL ADMIT TO. It missed "
              "the icon, or never reached the Finder's event stream. The "
              "next question is WHERE it went, not why the drag stalled.")
    print(f"   drag-sourced generations: "
          f"{[m.get('generation') for m in after if m.get('source') == 'drag']}")
    print(f"   selection-sourced:        "
          f"{[m.get('generation') for m in after if m.get('source') != 'drag']}")
    if latency:
        print("   " + latency)

    record = {
        "guest": link.hello, "arm": plane.arm,
        "preconditions": {"hidNow": a.hide, "frontedFinder": a.front,
                          "steps": a.steps, "dwell": a.dwell},
        "subject": subject, "aimedAt": spot,
        "selectionBefore": before_sel, "selectionAfter": after_sel,
        "boundsAfter": now, "moved": moved, "selected": selected,
        "baselineSelections": baseline, "midGestureSelections": mid,
        "afterReleaseSelections": after, "dragRows": rows,
        "grabs": grabs,
    }
    plane.disarm()
    if a.json:
        Path(a.json).write_text(json.dumps(record, indent=2, sort_keys=True))
        print(f"\n   record: {a.json}")
    return 0 if moved else 1


if __name__ == "__main__":
    sys.exit(main())
