#!/usr/bin/env python3
"""Probe the control op — NOW's `ctlact`, Mirror's `ctlinvoke` — against state.

Ported from `timbottu/mirror/tests/ctlinvoke-probe.py`.

## STATUS ON NOW TODAY: RUNS (the verb is served)

NOW's act plane is `elements` / `winact` / `textget` / `textset` / `ctlact` /
`menuact`. **The control op is `ctlact`**, and it takes exactly the arguments
this file already sent — `element` and `part`.

### The name, reconciled 2026-07-31

This file shipped asking for `ctlinvoke`, Mirror's spelling, on the reasoning
below that NOW "has not chosen one". NOW had: `ctlact` was declared in
`contract/asyncapi.yaml` (`x-commands`), given a `cmd_help.c` row, and served
by `now_act_run_ctlact` — by a different agent, on the same day. Neither saw
the other, so this harness would have reported *"missing verb: ctlinvoke"*
against a guest that serves precisely that capability: the loud-refusal
machinery producing a confident wrong answer.

The wire name moved to the guest's, because the guest's is the one that is
already declared in the contract, carried by a help row, and owed host rows —
four places against this file's one constant. The *result* label did not move:
`CASE` below stays `ctlinvoke` so a run here still diffs field-for-field
against upstream's numbers, which is what `upstream/PROVENANCE.md` exists to
protect. The two are separate things and this is the file where they part.

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
    ctlact     the control op. Declared in NOW's contract and served.

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

# The WIRE name: what this guest serves. NOW's act plane spells the control op
# `ctlact` (contract/asyncapi.yaml x-commands, cmd_help.c, act_cmds.c).
ACT_VERB = "ctlact"

# The RESULT name: what the numbers are filed under. Upstream's spelling, held
# fixed on purpose - see the docstring. Renaming this would silently break the
# field-for-field diff against scripts/probes/upstream/ that this port's whole
# comparability argument rests on.
CASE = "ctlinvoke"

REQUIRED = ("observe", ACT_VERB)

GATE_NOTE = """\
The control op is `ctlact` on this wire. If the guest does not serve it, the
guest predates NOW's act plane (P4) rather than disagreeing about a name -
check `help` for winact/textget/textset too.

The result label stays `ctlinvoke`, upstream's spelling, so the numbers remain
comparable with scripts/probes/upstream/. Wire name and result label are
deliberately different things here."""

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

    print(f"\n=== {ACT_VERB}: move a control, read its value back, N={args.n}"
          f"  (filed as {CASE!r} for upstream comparability)")
    trials = []
    for i in range(args.n):
        t = trial(link, i)
        trials.append(t)
        sys.stdout.write("!" if not t.get("valid", True) else
                         ("." if t.get("actuated") else
                          ("~" if t.get("replied") else "?")))
        sys.stdout.flush()
    print()
    results = [tally.rate_summary(CASE, trials)]
    tally.print_summary(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")
    link.close()
    return 0 if results[0]["n"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
