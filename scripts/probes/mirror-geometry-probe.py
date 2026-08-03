#!/usr/bin/env python3
"""Does the scene know where things are on the REAL screen?

    scripts/probes/mirror-geometry-probe.py --port 5251

## Why a probe and not a test

The host's `SceneHitTestTests` takes a control's rect, computes its centre,
hit-tests that point, and requires the same control back. That holds the
two halves of one document against each other - and it is **blind to any
offset they share**. Shift every window and every control by the same
twenty pixels and the round trip still closes; the arithmetic cancels.

Only the machine can answer the remaining question, so this asks it.
It computes a point the way a RENDERER places one - `rect.t +
titleBarHeight + control.rect.t`, which is how MirrorKit recovers the
content origin - delivers a real hardware click there through QMP, and
reads the control back over NOW's wire to see whether the Macintosh
agreed that something was under the cursor.

Then it clicks one title bar BELOW that point and requires that one to do
nothing, and requires the first to scroll DOWN rather than merely to
scroll. A probe that only checks the happy point cannot tell "the
geometry is right" from "this window is forgiving" - the first draft
displaced UPWARD, landed in the page-up region, watched the bar move, and
reported inconclusive on a build that was correct.

## What it caught

2026-08-02, first run. NOW emitted the CONTENT region as
`windows[].rect`, where IR v1 wants the content grown up by a title bar.
The renderer's point missed the scroll arrow by twenty pixels and the
machine did not move; the displaced point moved it (-4 to 60). Both host
gates were green, and the render looked correct.

## Reading a failure

- **Neither point moves.** Not necessarily geometry: check the window is
  frontmost, the control is live (`max > min + 1`), and that the cursor
  actually arrived - the landed position is printed, and QMP input is
  relative and accelerated, so a closed loop that ran out of tries lands
  short and this will look like a miss.
- **The renderer's point moves the bar the WRONG WAY.** It landed in a
  page region rather than the arrow: near the right place, not at it.
- **The displaced point moves and the renderer's point does not.** The
  producer and the IR disagree about which rectangle `windows[].rect`
  is. That is the defect above.
- **Both move.** The bar extends past where this expects it to end.
  Choose a shorter control or a tighter aim before believing it.
"""
import argparse
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import nowwire                                          # noqa: E402
import qmp as qmpmod                                     # noqa: E402

# MirrorKit.SceneBuilder.titleBarHeight, and the guest's
# kNowSceneIRTitleBarHeight. Stated in three places because it is a
# CONVENTION between a producer and a consumer that do not share a
# header; this probe is what keeps the three honest.
TITLEBAR = 20


def live_scrollbar(scene):
    """A tall scrollbar with a real range, in a foreign window."""
    for w in scene.get("windows") or []:
        if w.get("app") == "New Old World" or not w.get("visible"):
            continue
        for c in w.get("controls") or []:
            r = c.get("rect")
            if (r and c.get("enabled") and c.get("role") == "scrollbar"
                    and isinstance(c.get("max"), int)
                    and isinstance(c.get("min"), int)
                    and c["max"] > c["min"] + 1
                    and (r["b"] - r["t"]) > (r["r"] - r["l"]) * 3):
                return w, c
    return None, None


def value_of(scene, ref):
    for w in scene.get("windows") or []:
        for c in w.get("controls") or []:
            if c.get("ref") == ref:
                return c.get("value")
    return None


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    nowwire.add_link_args(ap)
    ap.add_argument("--qmp", required=True,
                    help="the session VM's QMP socket (run/qmp.sock)")
    ap.add_argument("--clicks", type=int, default=4)
    args = ap.parse_args()

    link = nowwire.link_from_args(args)
    link.command("front", line="Finder")
    time.sleep(1)
    link.command("script", {"source": 'tell application "Finder" to open '
                                      'folder "System Folder" of startup disk'})
    time.sleep(5)

    scene, _ = link.scene()
    win, ctl = live_scrollbar(scene)
    if not ctl:
        print("no live vertical scrollbar in a foreign window - open a "
              "folder whose contents overflow", file=sys.stderr)
        return 2

    wr, r = win["rect"], ctl["rect"]
    print(f"window {win['title']!r} rect={wr}")
    print(f"scrollbar rect={r} (content-relative) "
          f"value={ctl['value']} of {ctl['min']}..{ctl['max']}")

    # The down arrow, placed the way a renderer places it. Eight pixels
    # up from the bar's bottom is inside the 16-pixel arrow box and clear
    # of the grow box in the window's corner.
    cx = wr["l"] + (r["l"] + r["r"]) // 2
    cy = wr["t"] + TITLEBAR + r["b"] - 8

    qc = qmpmod.Qmp(args.qmp)

    def read_mouse():
        d = dict(link.command("mouseloc").get("mouseloc") or [])
        return int(d["x"]), int(d["y"])

    # THE DISPLACEMENT GOES DOWN, NOT UP, and that is the whole design
    # of the negative control. One title bar ABOVE the down arrow is the
    # page-up region, which scrolls the bar legitimately - a "moved" there
    # says nothing. One title bar BELOW is off the end of the vertical bar
    # entirely (the horizontal bar and the grow box live there), so a
    # vertical value that changes from it means the document's idea of
    # where this control sits is low by exactly one title bar, which is
    # the defect measured on 2026-08-02.
    results = {}
    for name, (x, y) in (("renderer", (cx, cy)),
                         ("displaced", (cx, cy + TITLEBAR))):
        before = value_of(link.scene()[0], ctl["ref"])
        landed = qmpmod.position(read_mouse, qc, x, y)
        for _ in range(args.clicks):
            qc.click()
            time.sleep(0.35)
        time.sleep(1.5)
        after = value_of(link.scene()[0], ctl["ref"])
        moved = (after is not None and before is not None and after != before)
        results[name] = (moved, before, after)
        print(f"\n-- {name:<9} asked ({x},{y}) landed {landed}")
        print(f"   value {before} -> {after}   "
              f"{'MOVED' if moved else 'no change'}")

    rendered, r_before, r_after = results["renderer"]
    displaced, _, _ = results["displaced"]
    # A DOWN arrow must scroll DOWN. Without this a page-up hit reads as
    # success, and the sign is the only thing that separates them.
    down = (rendered and r_after is not None and r_before is not None
            and r_after > r_before)

    print()
    if down and not displaced:
        print("PASS: the down arrow is where the document says, it scrolls "
              "DOWN, and one title bar below it is empty.")
        return 0
    if rendered and not down:
        print("FAIL: the point moved the bar the WRONG WAY - it landed in "
              "a page region, not the arrow. The control is near where "
              "the document says but not exactly; check the title-bar "
              "convention and the arrow size.")
        return 1
    if displaced and not rendered:
        print("FAIL: the control is one TITLE BAR below where the document "
              "says. `windows[].rect` is very likely the CONTENT region "
              "where IR v1 wants the box (content grown up by "
              f"{TITLEBAR}) - see kNowSceneIRTitleBarHeight.")
        return 1
    if rendered and displaced:
        print("INCONCLUSIVE: both points moved it, so the bar extends past "
              "where this expects it to end. Aim at a shorter control.")
        return 3
    print("INCONCLUSIVE: neither point moved it. Check the window is "
          "front and the cursor arrived (landed positions above).")
    return 3


if __name__ == "__main__":
    raise SystemExit(main())
