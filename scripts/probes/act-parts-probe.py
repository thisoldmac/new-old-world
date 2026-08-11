#!/usr/bin/env python3
"""Does `ctlact` drive a control by PART? The metal-shaped half of a click.

    scripts/probes/act-parts-probe.py --port 5251

## Why this one matters more than it looks

`mirror-geometry-probe.py` asks whether the document knows where things
are, and it answers with a real hardware click through QMP — so it can
only ever run on an emulator. This probe sends no mouse events at all. It
names a control by the reference the guest minted and a Control Manager
part, and the application's own `TrackControl` does the rest.

That is the difference between a mirror that works on a bench and one
that works on a PowerBook. Mirror's own action model resolves a scroll
arrow to a QMP press, which no real Macintosh has; NOW's act plane serves
the part, and **this probe runs unchanged on metal** (point `--port` at
the listener the machine dials).

## What it asserts

Both directions, and that is the whole design. A single "the value
changed" cannot tell a working part code from a control that drifted, a
window that scrolled for another reason, or a page region hit by luck.
Down must increase the value and up must return it — the part code is the
only thing that differs between the two calls.

## Reading a failure

- **`Dispatch` is not `dispatched`.** The act plane refused; its own
  reason is in the reply and is the answer. `act-plane-absent`,
  `-stale`, `-dark` mean the NOW Extension is not resident or not armed.
- **Dispatched, and the value does not move.** The click reached the
  application and the application did nothing with it — which is a real
  answer about that control, not a defect here. Check it is a live
  scrollbar (`max > min + 1`) in a window that is frontmost.
- **Both directions move it the same way.** The part code is not being
  honoured; the guest is treating every part as the same act.
"""
import argparse
import json
import pathlib
import sys
import time

HERE = pathlib.Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import nowwire                                          # noqa: E402

# The Control Manager's parts, as `ctlact` names them in its own
# bad-request text: 20 up, 21 down, 22 page-up, 23 page-down, 129 the
# indicator. MirrorKit maps Scrollbar.Part onto these in
# ActionModel.partCode, and the two must not drift.
LINE_UP, LINE_DOWN = 20, 21


def live_scrollbar(scene):
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


def main():
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    nowwire.add_link_args(ap)
    ap.add_argument("--presses", type=int, default=6)
    args = ap.parse_args()

    link = nowwire.link_from_args(args)

    def value(ref):
        scene, _ = link.scene()
        for w in scene.get("windows") or []:
            for c in w.get("controls") or []:
                if c.get("ref") == ref:
                    return c.get("value")
        return None

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
    ref = ctl["ref"]
    print(f"target {win['title']!r} {ref}")
    print(f"  value {ctl['value']} of {ctl['min']}..{ctl['max']}")

    start = value(ref)
    for n in range(args.presses):
        reply = link.command("ctlact", {"element": ref, "part": LINE_DOWN})
        if n == 0:
            print("  first reply:", json.dumps(reply)[:300])
    time.sleep(2)
    down = value(ref)
    print(f"\n  part {LINE_DOWN} (down) x{args.presses}: {start} -> {down}")

    if start is None or down is None:
        print("\nINCONCLUSIVE: the control left the scene mid-run.")
        return 3
    if down == start:
        print("\nFAIL: dispatched and the control did not move. Read the "
              "`Dispatch` row above - a refusal names itself.")
        return 1
    if down < start:
        print("\nFAIL: the down arrow scrolled UP.")
        return 1

    for _ in range(args.presses):
        link.command("ctlact", {"element": ref, "part": LINE_UP})
    time.sleep(2)
    back = value(ref)
    print(f"  part {LINE_UP} (up)   x{args.presses}: {down} -> {back}")

    if back is None or back >= down:
        print("\nFAIL: the up arrow did not scroll up. The part code is "
              "not being honoured - every part is acting the same.")
        return 1

    print("\nPASS: ctlact drives the control by part, both directions, "
          "with no mouse events at all - so this holds on metal too.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
