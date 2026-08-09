#!/usr/bin/env python3
"""Probe `winact` — move, resize, zoom, close ONE window — against guest state.

Ported from `archive/mirror-standalone-2026-08-09/tests/winact-probe.py`.

## STATUS ON NOW TODAY: REFUSES on `observe` only

`winact` is DECLARED in `contract/asyncapi.yaml` with its exact arguments:

    winact {window, action}                action in [move, resize, zoom, close]
           + left/top for move, width/height for resize

so this port is written against NOW's real spelling, not Mirror's. The only
missing piece is `observe`, which mints the `now-window-<uuid>` the verb takes.
Alongside textops-probe.py this is the closest lane to producing a number.

## The oracle

ALWAYS the window's own rect, re-read out of the guest through a separate
observation after the act. `ok:true` says the responder answered; it is not
evidence that anything moved, and upstream records FOUR RETRACTED FINDINGS
made of treating it as evidence.

NOW's contract states the same limit from the other side: "an ok reply means
the event was handed to the addressed element's own application, never that
the window moved... There is deliberately no `performed` field for a responder
to set true."

## Three traps this exists to avoid

  * **A reused window accumulates.** Trial 12 must be measured against the
    same machine state as trial 1, so every trial RESETS the window to a known
    rect first and asks for a target derived from that reset, not from
    wherever the previous trial left it. The "~9 actuations per boot" ceiling
    was an accumulating oracle, not a defect.
  * **A no-op that is correct is indistinguishable from a broken verb.**
    Asking a window to move where it already is proves nothing, so the target
    always differs from the reset position by a STATED amount.
  * **`close` can destroy a document.** The close case runs on an EMPTY,
    unmodified window, so the application's own close path has no
    save-changes dialog to raise. NOW's contract says the same: close "is
    destructive: an application may lose unsaved work, or may put up a save
    dialog nothing on this wire can answer."

## What this needs from NOW

    observe   to mint the window reference. Wave 2A of the fold-in.
    winact    declared in the contract, served by no guest yet.

Usage:

    NOW_METAL=1 python3 scripts/probes/winact-probe.py --port 5252
    NOW_METAL=1 python3 scripts/probes/winact-probe.py ... --case close
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

PROBE = "winact-probe"
REQUIRED = ("observe", "winact")

GATE_NOTE = """\
winact IS declared in contract/asyncapi.yaml with its exact argument shape
({window, action} plus left/top or width/height), and this harness is written
against that spelling. The blocker is `observe`: winact takes an opaque
"now-window-<uuid>" that only an observation can mint, and by design it cannot
express "whatever is frontmost". That refusal is the finding this whole
directory exists to make reproducible.

Wave 2A of docs/mirror-foldin-inventory.md is what unblocks it."""

# A reset position and size that fit an 800x600 screen with the menu bar
# (20px, Inside Macintosh: Macintosh Toolbox Essentials) clear of the top.
HOME = (60, 60)
HOME_SIZE = (420, 300)

# How far each case moves. Stated, not incidental: trap 2 says the target must
# differ from the reset by a known amount, and "known" means written down.
MOVE_BY = (80, 50)
RESIZE_BY = (120, 90)

CASES = ("move", "resize", "zoom", "close")


def observe(link, scope: str = "front") -> dict:
    return link.command("observe", {"scope": scope})


def windows(link) -> list:
    return observe(link).get("windows", [])


def window_by_ref(link, ref: str):
    for w in windows(link):
        if w.get("ref") == ref:
            return w
    return None


def a_window(link, want_empty: bool = False):
    """A window to act on.

    `want_empty` is the close case's precondition: an EMPTY, unmodified
    document window, so closing it cannot lose work and cannot raise a save
    dialog. A window the observation reports as modified is skipped rather
    than closed — this harness will not risk a document to complete a trial.
    """
    for w in windows(link):
        if not w.get("visible") or not w.get("rect"):
            continue
        if want_empty and w.get("modified"):
            continue
        return w
    return None


def reset(link, ref: str) -> dict | None:
    """Put the window at HOME with HOME_SIZE, and confirm it got there.

    Trap 1. A reset that silently failed would make every later trial measure
    an accumulated position, which is exactly the defect this file's header
    describes.
    """
    try:
        link.command("winact", {"window": ref, "action": "move",
                                "left": HOME[0], "top": HOME[1]})
        link.command("winact", {"window": ref, "action": "resize",
                                "width": HOME_SIZE[0],
                                "height": HOME_SIZE[1]})
    except (GuestError, TimeoutError):
        return None
    time.sleep(1.2)
    return window_by_ref(link, ref)


def trial(link, case: str, i: int) -> dict:
    w = a_window(link, want_empty=(case == "close"))
    if w is None:
        return {"trial": i + 1, "valid": False,
                "why": ("no empty unmodified window to close safely"
                        if case == "close" else "no visible window observed")}
    ref = w["ref"]

    if case != "close":
        w = reset(link, ref)
        if w is None or not w.get("rect"):
            return {"trial": i + 1, "valid": False,
                    "why": "the window would not reset to a known rect"}

    before = list(w["rect"])
    args = {"window": ref, "action": case}
    if case == "move":
        args["left"] = HOME[0] + MOVE_BY[0]
        args["top"] = HOME[1] + MOVE_BY[1]
    elif case == "resize":
        args["width"] = HOME_SIZE[0] + RESIZE_BY[0]
        args["height"] = HOME_SIZE[1] + RESIZE_BY[1]
    # zoom and close carry no geometry. NOW's contract: zoom takes none
    # "because the standard state is the application's to compute - a caller
    # that supplied one would be deciding what the window is for."

    replied = False
    code = None
    try:
        link.command("winact", args)
        replied = True
    except GuestError as exc:
        replied = True                 # rule 2
        code = exc.code
    except TimeoutError:
        replied = False

    time.sleep(1.5)
    after_w = window_by_ref(link, ref)
    after = list(after_w["rect"]) if after_w and after_w.get("rect") else None

    if case == "close":
        # The oracle is the window's ABSENCE from a fresh observation. Note
        # what the contract does NOT promise: "this verb does not promise the
        # window closes, it promises the application was asked."
        actuated = after_w is None
    elif after is None:
        return {"trial": i + 1, "valid": False, "replied": replied,
                "why": "the window could not be read back"}
    elif case == "move":
        actuated = (after[0], after[1]) == (args["left"], args["top"])
    elif case == "resize":
        actuated = (after[2] - after[0], after[3] - after[1]) == \
            (args["width"], args["height"])
    else:   # zoom — the app computes the standard state, so the only honest
            # assertion is that the rect CHANGED, by an amount we do not get
            # to predict.
        actuated = after != before

    return {"trial": i + 1, "case": case, "window": ref, "before": before,
            "after": after, "asked": {k: v for k, v in args.items()
                                      if k not in ("window", "action")},
            "replied": replied, "actuated": actuated, "error": code}


def run_case(link, case: str, n: int) -> dict:
    print(f"\n=== winact {case}, oracle = the window's own rect, N={n}")
    trials = []
    for i in range(n):
        t = trial(link, case, i)
        trials.append(t)
        sys.stdout.write("!" if not t.get("valid", True) else
                         ("." if t.get("actuated") else
                          ("~" if t.get("replied") else "?")))
        sys.stdout.flush()
    print()
    return tally.rate_summary(case, trials)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--case", action="append", choices=CASES)
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    link = link_from_args(args)
    link.require_verbs(PROBE, *REQUIRED, note=GATE_NOTE)

    # close is NOT in the default set. It is destructive and upstream ran it
    # deliberately; a default that closed windows would be a probe with a side
    # effect nobody asked for.
    cases = args.case or ["move", "resize", "zoom"]
    results = [run_case(link, c, args.n if c != "close" else min(args.n, 5))
               for c in cases]
    tally.print_summary(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")
    link.close()
    return 0 if all(r["n"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
