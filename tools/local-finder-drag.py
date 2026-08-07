#!/usr/bin/env python3
"""Does a Finder icon actually MOVE when NOW drags it?

    tools/local-finder-drag.py --port 19833 --expect-build auto

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody.

WHAT IT IS FOR, and why it is not `local-drag-vehicle.py`. That script
proved the vehicle: the Time Manager task fires, the button goes down and
stays, and the dead-man lets go by itself. It aims at NOW's OWN window and
says so, which means it proves nothing whatever about what an application
does with the gesture. `DragGrayRgn` has never been measured in this
project and the Finder has never been asked to move anything.

This asks the one question that was left: **an item that started in one
place and ended in another, named.** The oracle is the FINDER'S OWN
answer -- `bounds of` the item before and after -- not our arithmetic and
not a screenshot somebody interpreted. A screendump is taken beside it
because a person asked for the machine's own pixels, but the pass/fail is
the Finder's number.

WHAT IT DRAGS, and why that is the safe choice. A desktop icon, to an
empty spot on the same desktop. Same container, new position: the
ordinary Mac icon shuffle, which is a REARRANGEMENT rather than a move --
nothing is filed anywhere, nothing is opened with anything, and the worst
outcome is an icon in a different place. The destination is checked to be
clear of every other item the Finder reports before anything is pressed.
This script will not drop an icon ON something; aiming a drag at a
guessed target is how a drag moves the wrong file.

THE RULES IT ASSERTS, rather than the symptoms it happened to see. The
sibling lesson from `local-drag-vehicle.py` cost a run: its phase 4
required a REFUSAL that was a property of a bug elsewhere, and when
another lane fixed that bug the probe reported the fix as the defect. So
every check below is a rule the guest carries in its own source:

  * the window form refuses a point outside its window (obsref.h's
    "a coordinate is not a reference", made checkable);
  * the window form refuses without h and v (a container is not a point);
  * naming both element and window is refused (they mean different
    targets and nothing gets to pick);
  * and the item's position, as the FINDER reports it, differs after.

It refuses a guest whose hello build is not `--expect-build`: every QEMU
guest on this Mac sees the host as 10.0.2.2 and any session's VM can
answer this listener (AGENTS.md). `auto` reads the local build stamp.
"""

import argparse
import os
import re
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402

ICON = 32


def rows(reply, key):
    """The reply's display rows as a dict. A convenience, not a contract."""
    out = {}
    for row in (reply.get(key) or []) if isinstance(reply, dict) else []:
        if isinstance(row, list) and len(row) == 2:
            out[row[0]] = row[1]
    return out


def script(link, src, timeout=120):
    d = rows(link.command("script", {"source": src}, timeout=timeout),
             "script")
    if d.get("osaErr") not in (None, "0"):
        raise RuntimeError(f"AppleScript refused: osaErr={d.get('osaErr')}")
    raw = d.get("output") or ""
    # OSADoScript renders its result in SOURCE form, so text is quoted.
    if raw.startswith('"') and raw.endswith('"') and len(raw) >= 2:
        raw = raw[1:-1]
    return raw


def desktop_items(link):
    """Every desktop icon and the box the FINDER DREW, in global coords.

    `bounds of`, never `position of`: in a list view `position` answers
    the saved icon grid the window is not drawing, and the whole reason
    this project has trustworthy geometry is that it stopped asking the
    saved grid anything (MirrorKit's FinderItems header carries the
    measurement)."""
    raw = script(link,
                 'tell application "Finder"\nset r to ""\n'
                 'repeat with t in (get items of desktop)\n'
                 'set q to bounds of t\n'
                 'set r to r & (name of t) & "|" & (item 1 of q) & "," & '
                 '(item 2 of q) & "," & (item 3 of q) & "," & '
                 '(item 4 of q) & ";;"\nend repeat\nreturn r\nend tell')
    items = []
    for rec in raw.split(";;"):
        if not rec or "|" not in rec:
            continue
        name, _, box = rec.partition("|")
        try:
            l, t, r_, b = (int(n) for n in box.split(","))
        except ValueError:
            continue
        items.append({"name": name, "l": l, "t": t, "r": r_, "b": b})
    return items


def finder_psn(link):
    """The Finder's process serial number, out of the scene's own roster.

    Aimed rather than left to default. `elements` with no arguments walks
    the FRONT process, and what is frontmost is exactly the thing this
    script keeps changing -- so a walk that happened to catch NOW would
    report no Finder windows and read identically to a machine that has
    none."""
    doc = link.scene(full=True, timeout=180)[0]
    for proc in doc.get("processes") or []:
        if proc.get("name") == "Finder":
            hi, _, lo = str(proc.get("psn") or "").partition(".")
            if hi.isdigit() and lo.isdigit():
                return int(hi), int(lo)
    return None


def finder_windows(link, psn):
    """The Finder's windows as the GUEST's own element walk sees them.

    This is the half that had never been asked for. The desktop is an
    ordinary window in the window list, so the reference that names it is
    minted by the same walk that names every other window -- which is why
    dragpress's window form reaches a desktop icon at all."""
    el = link.command("elements",
                      {"serialHi": psn[0], "serialLo": psn[1]}, timeout=180)
    out = []
    for proc in (el.get("elements") or {}).get("processes") or []:
        if proc.get("name") != "Finder":
            continue
        for win in proc.get("windows") or []:
            out.append(win)
    return out


def clear_spot(items, avoid, w, h, bounds):
    """A destination box that overlaps nothing the Finder reported.

    Refused rather than guessed: if the desktop is too full to find one,
    this returns None and the run stops. A drag aimed at a spot we did
    not check is a drag that could drop a file INTO something."""
    for y in range(bounds["t"] + 40, bounds["b"] - h - 40, 24):
        for x in range(bounds["l"] + 40, bounds["r"] - w - 40, 24):
            box = (x, y, x + w, y + h)
            if any(it is not avoid
                   and not (box[2] <= it["l"] or box[0] >= it["r"]
                            or box[3] <= it["t"] or box[1] >= it["b"])
                   for it in items):
                continue
            return box
    return None


def refusal(link, verb, args, timeout=60):
    """Send something that must be refused, and hand back the sentence."""
    try:
        link.command(verb, args, timeout=timeout)
        return None
    except nowwire.GuestError as exc:
        return f"{exc}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=int, default=240)
    ap.add_argument("--expect-build", default="auto")
    ap.add_argument("--shot", default=None,
                    help="directory for before/after screendumps, if the "
                         "lab's tools/shot is reachable")
    args = ap.parse_args()

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = str(link.hello.get("build") or "")
    print(f"guest build: {build}")
    want = None if args.expect_build == "auto" else args.expect_build
    if want and want not in build:
        raise SystemExit(f"WRONG BUILD: wanted {want!r}, got {build!r}")

    print("\n== 0. the resident's drag vehicle, and the build under test ==")
    ext = (link.command("mirror", timeout=60).get("mirror") or {}) \
        .get("extension") or {}
    caps = ext.get("capabilities") or 0
    print(f"  resident {ext.get('lifecycle')}  caps={caps}")
    if not caps & 0x80:
        print("  FAIL: no drag vehicle (capability bit 7 clear).")
        return 1

    print("\n== 1. the Finder, and what it says is on its desktop ==")
    link.command("front", {"target": "Finder"}, timeout=60)
    time.sleep(1)
    items = desktop_items(link)
    for it in items:
        print(f"   {it['name']!r} at "
              f"{{{it['l']},{it['t']},{it['r']},{it['b']}}}")
    if not items:
        print("  INCONCLUSIVE: the Finder reports no desktop items, so "
              "there is nothing to pick up. Not a defect in the guest.")
        return 2

    psn = finder_psn(link)
    if psn is None:
        print("  INCONCLUSIVE: no Finder in the scene's process roster.")
        return 2
    wins = finder_windows(link, psn)
    desktop = next((w for w in wins if w.get("title") == "Desktop"), None)
    for w in wins:
        print(f"   window {w.get('title')!r} {w.get('bounds')} "
              f"ref={w.get('ref')}")
    if desktop is None:
        print("  INCONCLUSIVE: the guest's walk reports no Desktop window "
              "for the Finder, so the window form has nothing to name.")
        return 2
    b = desktop["bounds"]
    frame = {"l": b["left"], "t": b["top"], "r": b["right"], "b": b["bottom"]}

    subject = items[0]
    sw = subject["r"] - subject["l"]
    sh = subject["b"] - subject["t"]
    spot = clear_spot(items, subject, sw, sh, frame)
    if spot is None:
        print("  INCONCLUSIVE: no empty spot on this desktop that overlaps "
              "nothing. Refusing to drop an icon on something.")
        return 2
    start = ((subject["l"] + subject["r"]) // 2,
             (subject["t"] + subject["b"]) // 2)
    end = ((spot[0] + spot[2]) // 2, (spot[1] + spot[3]) // 2)
    print(f"\n  dragging {subject['name']!r} from {start} to {end} "
          f"(an empty spot on the same desktop: a rearrangement)")

    print("\n== 2. THE RULES THE WINDOW FORM CARRIES ==")
    ref = desktop["ref"]
    why = refusal(link, "dragpress", {"window": ref})
    print(f"   window with no point   -> {why}")
    if not why or "requires h and v" not in why:
        print("  FAIL: a container without a point must be refused. A "
              "window is not a place to press.")
        return 1
    why = refusal(link, "dragpress",
                  {"window": ref, "h": frame["r"] + 50, "v": frame["t"] + 10})
    print(f"   point outside the window -> {why}")
    if not why or "outside the window" not in why:
        print("  FAIL: a point outside the named window must be refused. "
              "Without that check the reference does not bound the press "
              "and this form IS a coordinate wearing a reference's "
              "clothes (obsref.h).")
        return 1
    why = refusal(link, "dragpress",
                  {"window": ref, "element": ref, "h": start[0],
                   "v": start[1]})
    print(f"   both names at once      -> {why}")
    if not why or "names both" not in why:
        print("  FAIL: element and window mean different targets and "
              "nothing here gets to pick one.")
        return 1

    print("\n== 3. the drag itself ==")
    r = link.command("dragpress",
                     {"window": ref, "h": start[0], "v": start[1],
                      "idle": 300, "cap": 600}, timeout=120)
    d = rows(r, "dragpress")
    print("   press:", {k: d[k] for k in
                        ("Window", "Point from", "State", "Button",
                         "Session") if k in d})
    if d.get("Button") != "down":
        print("  FAIL: the button is not down.")
        return 1
    session = int(d["Session"])

    steps = 6
    for i in range(1, steps + 1):
        h = start[0] + (end[0] - start[0]) * i // steps
        v = start[1] + (end[1] - start[1]) * i // steps
        d = rows(link.command("dragmove",
                              {"session": session, "h": h, "v": v},
                              timeout=60), "dragmove")
        time.sleep(0.25)
    print("   after the moves:", {k: d[k] for k in
                                  ("State", "At h", "At v", "Vehicle ticks",
                                   "Moves applied") if k in d})

    d = rows(link.command("dragrelease", {"session": session}, timeout=60),
             "dragrelease")
    print("   release:", {k: d[k] for k in ("State", "Ended") if k in d})

    print("\n== 4. THE ORACLE: what the Finder says now ==")
    time.sleep(2)
    after = {it["name"]: it for it in desktop_items(link)}
    now = after.get(subject["name"])
    if now is None:
        print(f"  FAIL: {subject['name']!r} is no longer on the desktop. "
              "That is worse than not moving.")
        return 1
    print(f"   before {{{subject['l']},{subject['t']}}}   "
          f"after {{{now['l']},{now['t']}}}   aimed at {spot[0]},{spot[1]}")
    if (now["l"], now["t"]) == (subject["l"], subject["t"]):
        print("  FAIL: the Finder reports the item where it started. The "
              "button went down, the vehicle ran, and DragGrayRgn did not "
              "follow -- which is the one thing this probe exists to tell "
              "apart from a refusal.")
        return 1
    print(f"  PASS: {subject['name']!r} started at "
          f"({subject['l']},{subject['t']}) and ended at "
          f"({now['l']},{now['t']}), by the Finder's own account.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
