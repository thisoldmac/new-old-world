#!/usr/bin/env python3
"""Probe the control op — Mirror's `ctlinvoke` — against guest state.

Ported from `timbottu/mirror/tests/ctlinvoke-probe.py`.

## STATUS ON NOW TODAY: REFUSES

NOW's declared act plane is `winact` / `textget` / `textset`. A control op is
NOT among them: `ctlinvoke` is on the unported list in
docs/mirror-foldin-inventory.md (Wave 3), and the inventory is explicit that
whether it should cross at all "is a judgement to make with the ported code in
front of us". This harness is checked in so that judgement is made with the
measurement available rather than re-derived, and it uses Mirror's verb name
because NOW has not chosen one.

## The oracle

ALWAYS the control's own value, read back through a separate observation.
`ok:true` only means the application's `TrackControl` returned our part code;
it is not evidence that anything happened.

## Two traps this exists to avoid, both of which already cost a cycle upstream

  * A scroll bar sitting at its MAXIMUM cannot page down. A no-op that is
    correct behaviour is indistinguishable from a broken verb unless the
    direction is chosen against the control's LIVE VALUE. So each trial reads
    the value first and picks the direction that has somewhere to go.
  * The Control Manager part codes are 20/21/22/23 (up button, down button,
    page up, page down) and 10/11 (button, check box) — Inside Macintosh, the
    Control Manager, and ControlDefinitions.h. **12 and 13 are NOT part
    codes**; asking for one is asking the app to do nothing. A phantom
    10/11/12/13 in a doc comment is what made the control op look broken for a
    day.

## What this needs from NOW

    observe    to mint the control reference and to read the value back.
    ctlinvoke  a control op. NOT declared in NOW's contract. If NOW spells it
               differently when it lands, this file's `ACT_VERB` is the one
               line to change.

Usage:

    NOW_METAL=1 python3 scripts/probes/ctlinvoke-probe.py --port 5252
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import tally                                                      # noqa: E402
from nowwire import (GuestError, add_link_args, link_from_args,   # noqa: E402
                     refuse_without_metal)

PROBE = "ctlinvoke-probe"

# Mirror's spelling, kept because NOW has not chosen one. One line to change.
ACT_VERB = "ctlinvoke"
REQUIRED = ("observe", ACT_VERB)

GATE_NOTE = """\
A control op is NOT in NOW's declared act plane (winact/textget/textset). It
is on the unported list in docs/mirror-foldin-inventory.md, Wave 3, where the
inventory says explicitly that whether it should cross at all is a judgement
to make with the ported code in front of us - not before.

This harness carries Mirror's verb name because NOW has not picked one. When
it lands under another name, ACT_VERB in this file is the single line to
change."""

# Inside Macintosh, the Control Manager (ControlDefinitions.h).
IN_BUTTON, IN_CHECKBOX = 10, 11
IN_UP_BUTTON, IN_DOWN_BUTTON = 20, 21
IN_PAGE_UP, IN_PAGE_DOWN = 22, 23
IN_THUMB = 129

# The four that move a scroll bar, and what each is worth as a discriminator.
# A page moves further than a line, which is how a hijack is told from a
# chain-through in nohijack-probe.py's control case.
SCROLL_PARTS = (IN_UP_BUTTON, IN_DOWN_BUTTON, IN_PAGE_UP, IN_PAGE_DOWN)


def observe(link, scope: str = "front") -> dict:
    return link.command("observe", {"scope": scope})


def controls(link) -> list:
    out = []
    for w in observe(link).get("windows", []):
        out.extend(w.get("controls", []))
    return out


def control_by_ref(link, ref: str):
    for c in controls(link):
        if c.get("ref") == ref:
            return c
    return None


def live_scroll_bar(link):
    """A visible control with a range that has somewhere left to go."""
    for c in controls(link):
        lo, hi, val = c.get("min"), c.get("max"), c.get("value")
        if None in (lo, hi, val) or hi <= lo or not c.get("visible"):
            continue
        return c
    return None


def choose_direction(control: dict):
    """Pick the part that has room to move. Trap 1, enforced.

    Returns (part, expected_sign). A bar at its maximum can only go up; a bar
    at its minimum can only go down. A bar in the middle prefers DOWN so that
    the trial's expectation matches nohijack-probe's chain-through direction.
    """
    lo, hi, val = control["min"], control["max"], control["value"]
    if val >= hi:
        return IN_PAGE_UP, -1
    if val <= lo:
        return IN_PAGE_DOWN, +1
    return IN_PAGE_DOWN, +1


def trial(link, i: int) -> dict:
    bar = live_scroll_bar(link)
    if bar is None:
        return {"trial": i + 1, "valid": False,
                "why": "no control with a live range in the observation"}
    part, sign = choose_direction(bar)
    before = bar["value"]

    replied = False
    code = None
    try:
        link.command(ACT_VERB, {"element": bar["ref"], "part": part})
        replied = True
    except GuestError as exc:
        replied = True                 # rule 2
        code = exc.code
    except TimeoutError:
        replied = False

    time.sleep(1.2)
    after = (control_by_ref(link, bar["ref"]) or {}).get("value")

    if after is None:
        # Unreadable state is not a clean trial. tally refuses to score
        # missing data as a negative and the trial is dropped here.
        return {"trial": i + 1, "valid": False, "replied": replied,
                "why": "the control could not be read back"}

    moved = after - before
    # The direction must be the one asked for. A control that moved the OTHER
    # way is not this verb working; it is something else moving the bar.
    actuated = (moved * sign) > 0

    return {"trial": i + 1, "control": bar["ref"], "part": part,
            "before": before, "after": after, "moved": moved,
            "expectedSign": sign, "replied": replied, "actuated": actuated,
            "error": code}


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    link = link_from_args(args)
    link.require_verbs(PROBE, *REQUIRED, note=GATE_NOTE)

    print(f"\n=== {ACT_VERB}: move a control, read its value back, N={args.n}")
    trials = []
    for i in range(args.n):
        t = trial(link, i)
        trials.append(t)
        sys.stdout.write("!" if not t.get("valid", True) else
                         ("." if t.get("actuated") else
                          ("~" if t.get("replied") else "?")))
        sys.stdout.flush()
    print()
    results = [tally.rate_summary(ACT_VERB, trials)]
    tally.print_summary(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")
    link.close()
    return 0 if results[0]["n"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
