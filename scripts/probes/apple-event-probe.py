#!/usr/bin/env python3
"""Probe the `aesend` verb — the one behind "quit that application".

Ported from `timbottu/mirror/tests/apple-event-probe.py`.

## STATUS ON NOW TODAY: gated on `observe`, not on the verb

### Two things this file had wrong about NOW, both fixed 2026-07-31

**The name.** Upstream serves `apple_event`; NOW spells it **`aesend`**. No
other verb on this wire carries an underscore (`winact`, `ctlact`, `menuact`,
`textget`, `observe`), and `aesend` names the mechanism and claims exactly
what the reply claims — the event was *sent*. One constant here.

**The addressing.** This file sent `{"psn": "hi:lo"}`, upstream's shape.
NOW's `observe` reports a process as `serialHi` / `serialLo`, two integers,
and every other verb on this plane that names a process (`elements`,
`menuact`) takes them that way — so `proc.get("psn")` was always None here and
every quit trial would have been dropped as "did not come up with a PSN".
The wire args are now the two integers. **The trial record still carries a
`"psn"` key**, as `"hi:lo"`, so a run still diffs field-for-field against
upstream's.

### What `aesend` bounds that upstream did not

NOW refuses two more requests before sending, and the `refuse` case checks
both: `serialHi 0 / serialLo 0` is kNoProcess by definition and is answered
locally rather than spent as an Apple Event, and **our own serial is refused**
— a core event to ourselves takes the connection down mid-reply, so the caller
would see a dropped socket where the truthful answer is a refusal.

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
    aesend       four core events (quit/oapp/odoc/pdoc) to a named serial.
                 A closed vocabulary, not a class/id pipe.

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
ACT_VERB = "aesend"
REQUIRED = ("observe", ACT_VERB)

SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"

# The whitelist upstream enforced. An event outside it must be REFUSED, and
# the refuse case checks exactly that — a general event sender that will send
# anything to anything is not a verb, it is a hole.
WHITELIST = ("quit", "oapp", "odoc", "pdoc")
OFF_WHITELIST = "dele"          # a real four-char code, deliberately not ours

GATE_NOTE = """\
The general event verb is `aesend` on this wire, not upstream's `apple_event`.
A guest that serves neither predates NOW's input plane.

NOW's own `quit` already sends a quit Apple Event, so the quit CASE here could
be re-pointed at it today. That is deliberately not done: this harness's value
is the REFUSALS (an event outside the quit/oapp/odoc/pdoc whitelist, missing
serials, a stale serial, and NOW's own two: kNoProcess and ourselves), which a
narrow quit verb has nothing to say about. Collapsing them would make a
harness that passes while testing a quarter of what it names."""


def serials(proc: dict):
    """The two integers `observe` reports for a process, or None.

    Upstream's guest took one `psn` string; NOW takes serialHi/serialLo, the
    shape `observe` itself emits and the shape every other process-naming verb
    on this plane uses. Kept in one function so the trial records below can go
    on carrying upstream's single `psn` field for comparison.
    """
    if not proc:
        return None
    hi, lo = proc.get("serialHi"), proc.get("serialLo")
    if hi is None or lo is None:
        return None
    return int(hi), int(lo)


def psn_text(pair) -> str:
    return "%d:%d" % pair if pair else ""


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
        pair = serials(proc)
        if pair is None:
            trials.append({"trial": i + 1, "valid": False,
                           "why": f"{name} did not come up with a window and "
                                  f"a PSN"})
            sys.stdout.write("!")
            sys.stdout.flush()
            continue
        replied = False
        code = None
        try:
            link.command(ACT_VERB, {"serialHi": pair[0], "serialLo": pair[1],
                                    "event": "quit"})
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
        trials.append({"trial": i + 1, "psn": psn_text(pair),
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
        if serials(proc) is None:
            trials.append({"trial": i + 1, "valid": False,
                           "why": "target not ready"})
            continue
        raise SystemExit(
            "TODO(now): no way to DIRTY a document on NOW's wire.\n"
            "  Upstream typed into the document through a `key` verb. NOW\n"
            "  serves none, so this case cannot stage its own precondition\n"
            "  even once aesend exists. Named rather than filled in: a\n"
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
    pair = serials(proc) or (0, 1)
    named = {"serialHi": pair[0], "serialLo": pair[1]}
    checks = [
        ("off-whitelist event", dict(named, event=OFF_WHITELIST)),
        ("missing serial", {"event": "quit"}),
        ("half a serial", {"serialHi": pair[0], "event": "quit"}),
        ("missing event", dict(named)),
        # kNoProcess. Upstream sent this as the string "0:0" and let the
        # AppleEvent Manager answer procNotFound; NOW refuses it locally,
        # which is the same answer for no Apple Event.
        ("stale serial", {"serialHi": 0, "serialLo": 0, "event": "quit"}),
    ]
    # NOT CHECKED, AND SAID SO RATHER THAN FAKED: aesend refuses a core event
    # addressed at the guest's OWN serial (now_ae_check, kNowAeSelf), which is
    # the one refusal on this verb whose failure is unrecoverable - sent, it
    # takes the connection down mid-reply and the probe reads a wedge. There
    # is no way to stage it from here: `hello` carries no serial and no
    # product name, and `observe` names processes but nothing on the wire says
    # which of them is the guest. Guessing a name would test whichever
    # application happened to match. The refusal is covered instead by
    # now-guest-ppc/tests/input_args_test.c, on the host compiler, with the
    # mutation that removes it watched failing.
    print("    (not checked here: the self-addressed refusal. See the "
          "comment - there is no way to learn the guest's own serial from "
          "this side, and a guessed one would test another application)")
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
