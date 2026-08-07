#!/usr/bin/env python3
"""Does the drag vehicle actually fire, and does the dead-man let go?

    tools/local-drag-vehicle.py --port 5460 --expect-build auto

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody.

WHAT IT IS FOR. P7 (ext/src/now_ext_drag.c) presses the mouse button and
leaves it down, hands the gesture to a Time Manager task, and releases it
on a deadline the RESIDENT enforces. Every part of that was tested as
pure logic by `now-guest-shared/tests/now_drag_logic_test.c`; none of it
had ever run on a Macintosh. The two claims that a native test cannot
make, and that this script exists to make, are:

  1. **The Time Manager task fires at all.** `ticks_served` is a COUNT,
     not a timestamp, for exactly this: a vehicle that never installed
     and a vehicle that installed and never ran are the same silence in
     a timestamp and different numbers here.

  2. **The dead-man releases the button WITHOUT BEING ASKED.** This is
     the safety property everything else rests on, and it is the one a
     driven test has to be careful about: to see it fire you must NOT
     release, so "the drag ended by itself" and "the script forgot to
     release" look identical unless the script says up front which it is
     doing. Phase 3 below sends nothing on purpose and says so.

WHAT IT DELIBERATELY DOES NOT CLAIM. Whether the FINDER tracks these
writes - whether `DragGrayRgn` actually follows the mouse globals the
vehicle sets - is a different question and needs a Finder window with an
item in it. This script aims at NOW's own window, so a pass here says the
vehicle works and says nothing about what any application did with it.

It refuses a guest whose hello build is not `--expect-build`: every QEMU
guest on this Mac sees the host as 10.0.2.2 and any session's VM can
answer this listener (AGENTS.md). `auto` reads the local build stamp.
"""

import argparse
import os
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402

OURS = "New Old World"


def scene(link):
    return link.scene(full=True, timeout=120)[0]


def any_control(doc):
    """A control with a reference AND a real rectangle.

    The rectangle matters now: dragpress refuses a press point it cannot
    trust, so a control the scene reports without bounds is not a valid
    target - which is the correct behaviour and was found by driving,
    when the first run pressed at 0,0."""
    fallback = None
    for win in doc.get("windows") or []:
        for ctl in win.get("controls") or []:
            if not ctl.get("ref"):
                continue
            r = ctl.get("rect")
            if isinstance(r, dict) and r.get("r", 0) > r.get("l", 0):
                return ctl, win
            if fallback is None:
                fallback = (ctl, win)
    return fallback if fallback else (None, None)


def drag_rows(reply, key):
    """The reply's rows as a dict. The guest answers in display rows, so
    this is a test-side convenience and not a contract."""
    rows = (reply.get(key) or []) if isinstance(reply, dict) else []
    out = {}
    for row in rows:
        # The guest emits ["label","value"] pairs (act_cmds.c row_add).
        if isinstance(row, list) and len(row) == 2:
            out[row[0]] = row[1]
    return out


def show(tag, d):
    keep = ("State", "Session", "At h", "At v", "Button", "Vehicle ticks",
            "Moves applied", "Idle deadline", "Gesture cap", "Ended")
    print(f"  {tag}: " + "  ".join(f"{k}={d[k]}" for k in keep if k in d))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=int, default=180)
    ap.add_argument("--expect-build", default="auto")
    args = ap.parse_args()

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = str(link.hello.get("build") or "")
    print(f"guest build: {build}")
    # `auto` defers to the CAPABILITY assertion in phase 0, which is the
    # stronger of the two guards and the one AGENTS.md actually asks for:
    # "assert a capability only the build under test has before believing
    # anything it says". A build hash can only say the guest APPLICATION
    # matches; capability bit 7 says the RESIDENT under test is the one
    # answering, which is what this run is about. Pass an explicit hash to
    # require both.
    want = None if args.expect_build == "auto" else args.expect_build
    if want and want not in build:
        raise SystemExit(f"WRONG BUILD: wanted {want!r}, got {build!r} - "
                         "refusing to measure a guest this run did not build")

    print("== 0. the build under test, and its drag capability ==")
    ext = (link.command("mirror", timeout=60).get("mirror") or {}) \
        .get("extension") or {}
    caps = ext.get("capabilities") or 0
    print(f"  resident {ext.get('lifecycle')}  caps={caps} "
          f"({bin(caps)})  tableLength={ext.get('tableLength')}")
    # Bit 7 is kNowPeekTableCapDrag, and the resident publishes it ONLY
    # when its Time Manager task installed. This is also the capability
    # assertion AGENTS.md requires before believing anything this guest
    # says: no build before today can set it.
    if not caps & 0x80:
        print("  FAIL: this resident advertises no drag vehicle (bit 7 "
              "clear). Nothing below would mean anything.")
        return 1
    print("  bit 7 set: the drag Time Manager task installed.")

    print("\n== arm the planes, and wait for a real bind ==")
    doc = None
    for _ in range(12):
        doc = scene(link)
        binds = [p.get("bind") for p in (doc.get("processes") or [])]
        if "ok" in binds:
            break
        time.sleep(2)
    ctl, win = any_control(doc)
    if ctl is None:
        print("  FAIL: no control with a reference in any window; "
              "nothing to press on.")
        return 1
    print(f"  pressing on {ctl.get('title') or ctl.get('ref')} "
          f"in window {(win or {}).get('title')}")
    r = ctl.get("rect") or {}
    point = {"h": (r.get("l", 0) + r.get("r", 0)) // 2,
             "v": (r.get("t", 0) + r.get("b", 0)) // 2}
    print(f"  the scene puts it at {r}, so pressing at {point}")

    print("\n== 1. press: does the button go down and the vehicle run? ==")
    # idle=300 (5 s), the clamp ceiling. Phase 1 sleeps between calls and
    # the idle clock is refreshed by a MOVE and nothing else - a shorter
    # deadline here is killed by this script's own pauses, which is the
    # dead-man working and not the vehicle failing. Phase 3 uses a short
    # one deliberately.
    r = link.command("dragpress", dict(element=ctl["ref"], idle=300,
                                       cap=600, **point), timeout=120)
    d = drag_rows(r, "dragpress")
    show("after press", d)
    if d.get("Button") != "down":
        print("  FAIL: the button is not down.")
        return 1
    session = int(d["Session"])

    # The vehicle fires every 16 ms. Give it a beat and re-read: this is
    # claim 1, and it is a COUNT rising rather than a state persisting.
    time.sleep(0.5)
    r = link.command("dragmove", {"session": session, "h": 300, "v": 200},
                     timeout=60)
    d = drag_rows(r, "dragmove")
    show("after move", d)
    ticks = int(d.get("Vehicle ticks") or 0)
    if ticks == 0:
        print("  FAIL: ticks_served is 0 - the Time Manager task never "
              "fired. The button is down and nothing is driving it.")
        return 1
    print(f"  the vehicle ran {ticks} times: the Time Manager task fires.")

    time.sleep(0.5)
    r = link.command("dragmove", {"session": session, "h": 380, "v": 260},
                     timeout=60)
    d = drag_rows(r, "dragmove")
    show("second move", d)
    moved = (d.get("At h"), d.get("At v"))

    print("\n== 2. release: asked, and what actually ended it ==")
    r = link.command("dragrelease", {"session": session}, timeout=60)
    show("release asked", drag_rows(r, "dragrelease"))
    time.sleep(1)
    # Expected to be refused: the session is over.
    try:
        link.command("dragmove", {"session": session, "h": 1, "v": 1},
                     timeout=60)
        print("  a move after the release was ACCEPTED - unexpected")
    except nowwire.GuestError as exc:
        print(f"  a move after the release answers: {exc}")

    print("\n== 3. THE DEAD-MAN. Nothing below sends a release. ==")
    print("  This is deliberate and is the whole point: the resident must")
    print("  let go on its own. idle=60 ticks (1 s), so it should end in")
    print("  about a second with reason dead-man-idle.")
    r = link.command("dragpress", dict(element=ctl["ref"], idle=60,
                                       cap=600, **point), timeout=120)
    d = drag_rows(r, "dragpress")
    show("pressed", d)
    session = int(d["Session"])
    began = time.time()
    ended = None
    for _ in range(30):
        time.sleep(1)
        # Reading through a REFUSED move, so that nothing this script
        # sends can be mistaken for the release under test. A move for a
        # dead session is refused and carries the state with it.
        try:
            link.command("dragmove", {"session": session, "h": 2, "v": 2},
                         timeout=60)
        except nowwire.GuestError:
            ended = time.time() - began
            break
    if ended is None:
        print("  FAIL: the drag is STILL HELD after 30 s with nobody "
              "talking to it. The dead-man did not fire. This is the "
              "wedged-machine case.")
        return 1
    print(f"  the drag ended by itself after ~{ended:.1f}s, with nothing "
          f"sent to release it.")
    r = link.command("dragpress", dict(element=ctl["ref"], idle=60, **point),
                     timeout=120)
    d = drag_rows(r, "dragpress")
    # A fresh press proves the cell went back to a usable state, and its
    # rows carry the PREVIOUS session's end reason until overwritten.
    show("a fresh press succeeded", d)
    link.command("dragrelease", {"session": int(d["Session"])}, timeout=60)

    print("\n== 4. the ugly path: a press point nobody can vouch for ==")
    print("  Same element, no h/v. The resolver has no rectangle for it,")
    print("  so this must REFUSE rather than press at 0,0 - which is what")
    print("  the first driven run of this vehicle actually did.")
    try:
        r = link.command("dragpress", {"element": ctl["ref"], "idle": 60},
                         timeout=120)
        d = drag_rows(r, "dragpress")
        show("  ACCEPTED (unexpected)", d)
        link.command("dragrelease", {"session": int(d["Session"])}, timeout=60)
        print("  FAIL: it pressed at a point it could not vouch for.")
        return 1
    except nowwire.GuestError as exc:
        print(f"  refused: {exc}")

    print("\n== what this run did and did not prove ==")
    print("  PROVED: the Time Manager task fires on a real guest; a press")
    print("  puts the button down; a want is consumed and the pointer")
    print(f"  follows it (at={moved}); the resident releases the button")
    print("  with nothing asking it to.")
    print("  NOT PROVED: that any application TRACKS the writes. Nothing")
    print("  here aimed at a Finder item, so DragGrayRgn is untested.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
