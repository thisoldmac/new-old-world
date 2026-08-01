#!/usr/bin/env python3
"""Probe the `apple_event` verb — the one behind "quit that application".

Ported from `timbottu/mirror/tests/apple-event-probe.py`.

## STATUS ON NOW TODAY: REFUSES

`apple_event` is on the unported Wave 3 list in
docs/mirror-foldin-inventory.md. NOW does serve `quit`, which reaches the same
place for the one case that matters most — so read the note under "The overlap
with NOW's own quit" before deciding this lane is blocked.

## Measured against GUEST STATE, never the verb's own reply

An Apple Event verb is fire-and-forget (`kAENoReply`), so `sent:true` says
only that the event left the responder. The oracle for a quit is the target
LEAVING the process table.

## Three cases, and why the middle one passes either way

  quit    launch an application, send the quit event to its PSN, and require
          the process to disappear.
  dirty   the same application with an UNSAVED document. A quit Apple Event
          then raises a save-changes alert and the app STAYS RUNNING. That is
          the documented behaviour of a well-behaved application, not a
          failure of the verb — the probe reports which of the two happened
          and passes either way, because forcing it would mean discarding a
          document.
  refuse  the refusals: an event outside the quit/oapp/odoc/pdoc whitelist,
          missing serials, and a PSN that no longer names a process.

The `dirty` case is the one most likely to be quietly broken in a port,
because "passes either way" is one careless edit from "always passes". It
therefore records WHICH of the two outcomes happened, and a run in which every
dirty trial reported the same outcome is worth looking at.

## The overlap with NOW's own `quit`

NOW already serves `quit`, which sends a quit Apple Event and is covered by
`now-guest-ppc/src/processes/proc_quit_args.c` (parsed identically by both
guests — there is a parity test). So the `quit` CASE below could be re-pointed
at NOW's verb today and would measure something real.

It is NOT re-pointed, deliberately. This harness measures the general
apple-event verb — an arbitrary event to an arbitrary PSN, and its REFUSALS,
which is where a general event sender is dangerous and where NOW's narrow
`quit` has nothing to say. Collapsing the two would produce a harness that
passes while testing a quarter of what it names. If NOW wants a quit
measurement today, that is g1-probe.py's shape and it is three lines; this
file is the one that gates a general event verb.

## What this needs from NOW

    observe      to find the target's PSN and to see it leave.
                 (`ps` is a partial substitute and is used for the process
                 list, but a PSN is not on NOW's wire today.)
    apple_event  not declared, not served, Wave 3.

Usage:

    NOW_METAL=1 python3 scripts/probes/apple-event-probe.py --port 5252 \\
        --case quit
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import oracles                                                    # noqa: E402
import tally                                                      # noqa: E402
from nowwire import (GuestError, add_link_args, link_from_args,   # noqa: E402
                     refuse_without_metal)

PROBE = "apple-event-probe"
ACT_VERB = "apple_event"
REQUIRED = ("observe", ACT_VERB)

SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"

# The whitelist upstream enforced. An event outside it must be REFUSED, and
# the refuse case checks exactly that — a general event sender that will send
# anything to anything is not a verb, it is a hole.
WHITELIST = ("quit", "oapp", "odoc", "pdoc")
OFF_WHITELIST = "dele"          # a real four-char code, deliberately not ours

GATE_NOTE = """\
apple_event is Wave 3 in docs/mirror-foldin-inventory.md - unported, and the
inventory says a judgement about whether it should cross belongs with the
ported code in front of us.

NOW's own `quit` already sends a quit Apple Event, so the quit CASE here could
be re-pointed at it today. That is deliberately not done: this harness's value
is the REFUSALS (an event outside the quit/oapp/odoc/pdoc whitelist, missing
serials, a stale PSN), which a narrow quit verb has nothing to say about.
Collapsing them would make a harness that passes while testing a quarter of
what it names."""


def observe(link, scope: str = "all") -> dict:
    return link.command("observe", {"scope": scope})


def process_by_name(link, name: str):
    for p in observe(link).get("processes", []):
        if p.get("name") == name:
            return p
    return None


def windows_of(link, name: str) -> list:
    return [w for w in observe(link).get("windows", [])
            if w.get("app") == name]


def ensure_running(link, path: str, name: str, timeout: float = 30.0):
    """Start the target if it is not up, and wait for its WINDOW.

    An app that is still opening has not yet installed its AE handlers, and a
    quit sent into that gap measures the race and not the verb. This is the
    exact reason `ps` is not good enough as a readiness signal here, and it is
    why this harness needs `observe` even though NOW can list processes.
    """
    if not oracles.is_running(link, name):
        link.command("launch", {"target": path}, timeout=60)
    t0 = time.time()
    while time.time() - t0 < timeout:
        if windows_of(link, name):
            return process_by_name(link, name)
        time.sleep(1.0)
    return None


def case_quit(link, app: str, n: int) -> dict:
    name = app.rsplit(":", 1)[-1]
    print(f"\n=== quit {name!r} by Apple Event, oracle = it leaves, N={n}")
    trials = []
    for i in range(n):
        proc = ensure_running(link, app, name)
        if proc is None or not proc.get("psn"):
            trials.append({"trial": i + 1, "valid": False,
                           "why": f"{name} did not come up with a window and "
                                  f"a PSN"})
            sys.stdout.write("!")
            sys.stdout.flush()
            continue
        replied = False
        code = None
        try:
            link.command(ACT_VERB, {"psn": proc["psn"], "event": "quit"})
            replied = True
        except GuestError as exc:
            replied, code = True, exc.code
        except TimeoutError:
            replied = False
        gone = False
        for _ in range(20):
            time.sleep(1.0)
            if not oracles.is_running(link, name):
                gone = True
                break
        trials.append({"trial": i + 1, "psn": proc.get("psn"),
                       "replied": replied, "actuated": gone, "error": code})
        sys.stdout.write("." if gone else ("~" if replied else "?"))
        sys.stdout.flush()
    print()
    return tally.rate_summary("quit", trials)


def case_dirty(link, app: str, n: int) -> dict:
    """A quit event to an application with UNSAVED work.

    Both outcomes are correct and the probe passes either way. What it must
    not do is stop distinguishing them, so `outcome` is recorded per trial and
    printed as a breakdown — a run where every trial reported the same thing
    is the signature of this case having quietly stopped testing.
    """
    name = app.rsplit(":", 1)[-1]
    print(f"\n=== quit {name!r} WITH UNSAVED WORK, N={n} "
          f"(both outcomes are correct)")
    trials = []
    for i in range(n):
        proc = ensure_running(link, app, name)
        if proc is None or not proc.get("psn"):
            trials.append({"trial": i + 1, "valid": False,
                           "why": "target not ready"})
            continue
        raise SystemExit(
            "TODO(now): no way to DIRTY a document on NOW's wire.\n"
            "  Upstream typed into the document through a `key` verb. NOW\n"
            "  serves none, so this case cannot stage its own precondition\n"
            "  even once apple_event exists. Named rather than filled in: a\n"
            "  case that silently ran against a CLEAN document would report\n"
            "  the quit case's numbers under the dirty case's name, which is\n"
            "  the worst outcome available here.")
    return tally.rate_summary("dirty", trials)


def case_refuse(link, app: str) -> dict:
    """The refusals. Each one is a trial whose ACTUATION is a refusal.

    Inverted on purpose: here `ok:false` with the right code IS the pass. A
    verb that accepted any of these would be the hole this case exists to
    find, and it would look like a working verb in every other case.
    """
    name = app.rsplit(":", 1)[-1]
    proc = ensure_running(link, app, name)
    psn = (proc or {}).get("psn")
    checks = [
        ("off-whitelist event", {"psn": psn, "event": OFF_WHITELIST}),
        ("missing psn", {"event": "quit"}),
        ("missing event", {"psn": psn}),
        ("stale psn", {"psn": "0:0", "event": "quit"}),
    ]
    print(f"\n=== refusals ({len(checks)} checks; a refusal is the PASS)")
    trials = []
    for i, (label, args) in enumerate(checks):
        refused = False
        code = None
        try:
            link.command(ACT_VERB, args)
        except GuestError as exc:
            refused, code = True, exc.code
        except TimeoutError:
            pass
        trials.append({"trial": i + 1, "check": label, "replied": True,
                       "actuated": refused, "error": code})
        print(f"    {label:22} {'refused ' + str(code) if refused else '!! ACCEPTED'}")
    return tally.rate_summary("refuse", trials)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--case", action="append",
                    choices=("quit", "dirty", "refuse"))
    ap.add_argument("--app", default=SIMPLETEXT)
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    link = link_from_args(args)
    link.require_verbs(PROBE, *REQUIRED, note=GATE_NOTE)

    results = []
    for case in (args.case or ["quit", "refuse"]):
        if case == "quit":
            results.append(case_quit(link, args.app, args.n))
        elif case == "dirty":
            results.append(case_dirty(link, args.app, args.n))
        elif case == "refuse":
            results.append(case_refuse(link, args.app))
    tally.print_summary(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
    link.close()
    return 0 if all(r["n"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
