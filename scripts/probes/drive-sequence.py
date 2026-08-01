#!/usr/bin/env python3
"""Drive the guest through a real multi-step task and verify each step.

Ported from `timbottu/mirror/tests/drive-sequence.py`.

## STATUS ON NOW TODAY: REFUSES

## What it proves that a per-verb probe cannot

Single verbs passing is not the same as being able to DRIVE. This does a
sequence of mixed actions and checks every one against guest state, so "we can
drive a Mac OS 9 machine" becomes a claim with a receipt. Specifically:

  * a click's EFFECT on a real target, not merely that the cursor moved — it
    closes a window by its close box, using geometry the observation itself
    reported;
  * an act verb's SUCCESS path, by finding a control that is actually visible
    AND enabled. Most are not: upstream records Graphing Calculator exposing
    eleven controls of which ten are hidden and the last is disabled. A
    sequence that did not check would measure a refusal and call it a step;
  * that a sequence SURVIVES ITS OWN SIDE EFFECTS, which is where every
    earlier measurement on this project went wrong.

The third is the one that cannot be recovered by running the per-verb probes
back to back, and it is why this file is not redundant with them.

## What this needs from NOW

Everything the act plane needs, plus the reference layer:

    observe    to see the machine and mint references         (Wave 2A)
    winact     declared, unserved — the close step
    ctlinvoke  unported — the control step                    (Wave 3)
    launch     SERVED TODAY
    ps         SERVED TODAY

So two of the six steps below can already run, which is not enough for a
sequence: the value of this harness is precisely that the steps run in ORDER
against one machine. Running the two that work would be a subset with a
sequence's name on it.

Usage:

    NOW_METAL=1 python3 scripts/probes/drive-sequence.py --port 5252
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import oracles                                                    # noqa: E402
from nowwire import (GuestError, add_link_args, link_from_args,   # noqa: E402
                     refuse_without_metal)

PROBE = "drive-sequence"
REQUIRED = ("observe", "winact", "ctlinvoke", "launch", "ps")

SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"

GATE_NOTE = """\
This harness's value is that its steps run IN ORDER against one machine. Two
of its six steps (launch, ps) work on this guest today, and running only those
would be a subset carrying a sequence's name - which is the failure mode this
directory's README calls out.

Blocked on Wave 2A (observe) and the act plane."""


def observe(link, scope="all"):
    return link.command("observe", {"scope": scope})


def step(name, fn, steps):
    """Run one step, record what the GUEST said afterwards, and stop on the
    first failure.

    Stopping is deliberate. A sequence that continues past a failed step is
    measuring a machine in a state no step asked for, and its later steps'
    results mean nothing — which is exactly the "survives its own side
    effects" property this harness exists to check.
    """
    print(f"\n--- {name}")
    try:
        ok, detail = fn()
    except (GuestError, TimeoutError) as exc:
        ok, detail = False, f"{type(exc).__name__}: {exc}"
    steps.append({"step": name, "ok": bool(ok), "detail": detail})
    print(f"    {'ok' if ok else 'FAILED'}: {detail}")
    return bool(ok)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--app", default=SIMPLETEXT)
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    link = link_from_args(args)
    link.require_verbs(PROBE, *REQUIRED, note=GATE_NOTE)

    name = args.app.rsplit(":", 1)[-1]
    steps = []

    def launch():
        link.command("launch", {"target": args.app}, timeout=60)
        for _ in range(20):
            time.sleep(1.0)
            if oracles.is_running(link, name):
                return True, f"{name} is in the guest's process table"
        return False, f"{name} never appeared in `ps`"

    def see_a_window():
        wins = [w for w in observe(link).get("windows", [])
                if w.get("app") == name and w.get("visible")]
        return bool(wins), f"{len(wins)} visible window(s) for {name}"

    def move_it():
        w = next((w for w in observe(link).get("windows", [])
                  if w.get("app") == name and w.get("rect")), None)
        if w is None:
            return False, "no window with a rect"
        before = list(w["rect"])
        link.command("winact", {"window": w["ref"], "action": "move",
                                "left": before[0] + 40, "top": before[1] + 30})
        time.sleep(1.5)
        after = next((x["rect"] for x in observe(link).get("windows", [])
                      if x.get("ref") == w["ref"]), None)
        return (after is not None and list(after)[:2]
                == [before[0] + 40, before[1] + 30]), \
            f"{before} -> {after}"

    def find_a_live_control():
        """Most controls are neither visible nor enabled. See the docstring."""
        live = []
        for w in observe(link).get("windows", []):
            for c in w.get("controls", []):
                if c.get("visible") and c.get("enabled"):
                    live.append(c)
        return bool(live), (f"{len(live)} visible AND enabled control(s); "
                            f"a sequence that skipped this check would have "
                            f"measured a refusal and called it a step")

    def poke_that_control():
        live = [c for w in observe(link).get("windows", [])
                for c in w.get("controls", [])
                if c.get("visible") and c.get("enabled")
                and c.get("value") is not None]
        if not live:
            return False, "no live control with a readable value"
        c = live[0]
        before = c["value"]
        link.command("ctlinvoke", {"element": c["ref"], "part": 23})
        time.sleep(1.2)
        after = next((x.get("value") for w in observe(link).get("windows", [])
                      for x in w.get("controls", [])
                      if x.get("ref") == c["ref"]), None)
        return after is not None and after != before, f"{before} -> {after}"

    def close_it():
        w = next((w for w in observe(link).get("windows", [])
                  if w.get("app") == name and not w.get("modified")), None)
        if w is None:
            return False, "no unmodified window; refusing to close one that " \
                          "could lose work"
        link.command("winact", {"window": w["ref"], "action": "close"})
        time.sleep(2.0)
        still = any(x.get("ref") == w["ref"]
                    for x in observe(link).get("windows", []))
        return not still, ("the window is gone from a fresh observation"
                           if not still else "the window is still there")

    for label, fn in (("launch the application", launch),
                      ("see its window in an observation", see_a_window),
                      ("move that window and read the rect back", move_it),
                      ("find a control that is visible AND enabled",
                       find_a_live_control),
                      ("move that control and read its value back",
                       poke_that_control),
                      ("close the window and see it leave", close_it)):
        if not step(label, fn, steps):
            break

    done = sum(1 for s in steps if s["ok"])
    print(f"\n--- {done}/{len(steps)} steps completed "
          f"(of 6 in the full sequence)")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "steps": steps}, fh, indent=2)
    link.close()
    return 0 if done == 6 else 1


if __name__ == "__main__":
    raise SystemExit(main())
