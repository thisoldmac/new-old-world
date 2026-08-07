#!/usr/bin/env python3
"""The flicker instrument's own arithmetic, tested where no VM is needed.

WHY THIS EXISTS. `tools/fidelity-live.py` produces the number plan 018's
A/B rests on. An instrument that miscounts does not fail — it reports a
plausible wrong number, which is worse than no instrument, and this
repository has already written that lesson down for the wire-latency
histogram (`loopstat_test.c`).

Two properties matter more than any other, and each is asserted in both
directions here:

  * A ONE-WAY CHANGE IS NOT A FLICKER. A window that gains content and
    keeps it is the machine doing what it was asked. If this test's
    `no_flicker` cases ever score above zero, every number the sweep
    reports is inflated and the B side will look like a regression that
    never happened.
  * A RETURN IS. Content present, absent, present again — that is
    exactly Michelle's complaint #1, and the analyser must name the
    window it happened in, not merely count it.

Run: python3 tools/mirror-gate-tests/test_flicker_analysis.py
"""

import importlib.machinery
import importlib.util
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
TOOLS = os.path.dirname(HERE)


def load(name, filename):
    spec = importlib.util.spec_from_loader(
        name, importlib.machinery.SourceFileLoader(
            name, os.path.join(TOOLS, filename)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


live = load("fidelity_live", "fidelity-live.py")

FAILURES = []


def check(label, actual, expected):
    if actual != expected:
        FAILURES.append("%s: expected %r, got %r" % (label, expected, actual))


def frame(at, snapshot_id, windows, coverage=None):
    return {
        "at": at, "snapshotID": snapshot_id, "sequence": snapshot_id,
        "digest": "d%d" % snapshot_id, "baseComplete": True,
        "sceneGeneration": snapshot_id, "contentGeneration": snapshot_id,
        "guest": "g", "session": "s",
        "coverage": coverage or {}, "windows": windows,
    }


def window(display_total=0, item_total=0, owners=None, title="W"):
    return {"title": title, "rect": "0,0,100,100", "visible": True,
            "front": True, "z": 0, "displayTotal": display_total,
            "itemTotal": item_total,
            "wouldHatch": not (display_total or item_total),
            "owners": owners or {}}


# -- 1. a settled render is not a flicker ---------------------------------
still = [frame(t, 100 + t, {"w1": window(display_total=40)})
         for t in range(0, 12)]
report = live.analyse(still, provoked_at=0, settle_quiet=5)
check("still/flickerEvents", report["flickerEvents"], 0)
check("still/settled", report["settled"], True)
check("still/missed", report["snapshotIDs"]["missed"], 0)

# -- 2. a ONE-WAY change is not a flicker ---------------------------------
# The window had nothing, then got content, and kept it. This is the case
# that decides whether the number means anything: if a redraw counts as a
# flicker, every target scores non-zero and the axis is noise.
oneway = ([frame(t, 200 + t, {"w1": window(display_total=0)})
           for t in range(0, 3)]
          + [frame(t, 200 + t, {"w1": window(display_total=40)})
             for t in range(3, 14)])
report = live.analyse(oneway, provoked_at=2, settle_quiet=5)
check("oneway/flickerEvents", report["flickerEvents"], 0)
check("oneway/hatchFlips",
      report["flickerBreakdown"]["windowHatchFlips"], 0)
check("oneway/settled", report["settled"], True)
check("oneway/msToSettle", report["msToSettle"], 1000)

# -- 3. content present → absent → present IS a flicker -------------------
# Michelle's complaint #1, in its smallest form.
blink = ([frame(0, 300, {"w1": window(display_total=40)}),
          frame(1, 301, {"w1": window(display_total=0)}),
          frame(2, 302, {"w1": window(display_total=40)})]
         + [frame(t, 300 + t, {"w1": window(display_total=40)})
            for t in range(3, 14)])
report = live.analyse(blink, provoked_at=0, settle_quiet=5)
check("blink/dropouts",
      report["flickerBreakdown"]["windowContentDropouts"], 1)
check("blink/hatchFlips",
      report["flickerBreakdown"]["windowHatchFlips"], 1)
check("blink/flickerEvents", report["flickerEvents"], 2)
detail = report["flickerDetail"]["windowContentDropouts"][0]
check("blink/names-the-window", detail["window"], "w1")
check("blink/names-the-title", detail["title"], "W")

# -- 4. a rectangle's OWNER returning is a flicker ------------------------
# ink → unknown → ink, which is the signature the arc exists to fix.
owners_seq = ["ink", "unknown", "ink", "ink", "ink", "ink",
              "ink", "ink", "ink", "ink", "ink", "ink"]
flip = [frame(t, 400 + t,
              {"w1": window(display_total=40, item_total=1,
                            owners={"10,10,50,50": owner})})
        for t, owner in enumerate(owners_seq)]
report = live.analyse(flip, provoked_at=0, settle_quiet=5)
check("owner/rectOwnerFlips",
      report["flickerBreakdown"]["rectOwnerFlips"], 1)
detail = report["flickerDetail"]["rectOwnerFlips"][0]
check("owner/from", detail["from"], "ink")
check("owner/via", detail["via"], "unknown")
check("owner/rect", detail["rect"], "10,10,50,50")

# ink → semantic, and it stays semantic: a re-classification, not a
# flicker. This is the case that keeps the axis from firing on the fix.
settle_seq = ["ink", "semantic", "semantic", "semantic", "semantic",
              "semantic", "semantic", "semantic", "semantic", "semantic"]
resolve = [frame(t, 500 + t,
                 {"w1": window(display_total=40, item_total=1,
                               owners={"10,10,50,50": owner})})
           for t, owner in enumerate(settle_seq)]
report = live.analyse(resolve, provoked_at=0, settle_quiet=5)
check("resolve/rectOwnerFlips",
      report["flickerBreakdown"]["rectOwnerFlips"], 0)

# THREE states, none of them returning: unknown → ink → semantic, which
# is what a HEALTHY redraw looks like as the planes arrive in order.
#
# This case is here because the suite did not have it, and an experiment
# proved the omission mattered: replacing the `A == C` test in `_returns`
# with `if True` — i.e. counting every change as a flicker — left every
# other case in this file green, because none of them had more than two
# changes and the check never ran. The gate read green over an analyser
# that would have scored a perfectly clean redraw as flicker, which is
# precisely the failure mode a broken instrument has: a plausible wrong
# number rather than an error.
progressive = ([frame(0, 550, {"w1": window(display_total=0, item_total=1,
                                            owners={"1,1,9,9": "unknown"})}),
                frame(1, 551, {"w1": window(display_total=40, item_total=1,
                                            owners={"1,1,9,9": "ink"})}),
                frame(2, 552, {"w1": window(display_total=40, item_total=1,
                                            owners={"1,1,9,9": "semantic"})})]
               + [frame(t, 550 + t,
                        {"w1": window(display_total=40, item_total=1,
                                      owners={"1,1,9,9": "semantic"})})
                  for t in range(3, 14)])
report = live.analyse(progressive, provoked_at=0, settle_quiet=5)
check("progressive/rectOwnerFlips",
      report["flickerBreakdown"]["rectOwnerFlips"], 0)
check("progressive/flickerEvents", report["flickerEvents"], 0)
check("progressive/distinctStates",
      report["distinctStatesAfterProvocation"], 3)

# -- 5. coverage status returning is a flicker ----------------------------
cov = ([frame(0, 600, {}, {"windows/A": "complete"}),
        frame(1, 601, {}, {"windows/A": "stale"}),
        frame(2, 602, {}, {"windows/A": "complete"})]
       + [frame(t, 600 + t, {}, {"windows/A": "complete"})
          for t in range(3, 14)])
report = live.analyse(cov, provoked_at=0, settle_quiet=5)
check("coverage/flips",
      report["flickerBreakdown"]["coverageStatusFlips"], 1)

# -- 6. a run that never settles says so, and does NOT say a duration -----
# "settled at 45 s" and "never settled in 45 s" are opposite results; the
# `-` that was written 0 is a mistake this repository has paid for.
churn = [frame(t, 700 + t, {"w1": window(display_total=(t % 2) * 40)})
         for t in range(0, 20)]
report = live.analyse(churn, provoked_at=0, settle_quiet=5)
check("churn/settled", report["settled"], False)
check("churn/msToSettle", report["msToSettle"], None)
check("churn/framesToSettle", report["framesToSettle"], None)
if report["flickerEvents"] < 10:
    FAILURES.append("churn/flickerEvents: expected a large count, got %r"
                    % report["flickerEvents"])

# -- 7. missed snapshots are counted, so a number is known to be a floor --
gappy = [frame(0, 800, {"w1": window(display_total=1)}),
         frame(1, 803, {"w1": window(display_total=1)}),
         frame(2, 804, {"w1": window(display_total=1)}),
         frame(3, 805, {"w1": window(display_total=1)}),
         frame(4, 806, {"w1": window(display_total=1)}),
         frame(5, 807, {"w1": window(display_total=1)}),
         frame(6, 808, {"w1": window(display_total=1)})]
report = live.analyse(gappy, provoked_at=0, settle_quiet=5)
check("gappy/missed", report["snapshotIDs"]["missed"], 2)

# -- 8. a trace that changed guest mid-run is VOID, not a low score -------
mixed = [frame(0, 900, {"w1": window(display_total=1)}),
         dict(frame(1, 901, {"w1": window(display_total=1)}), guest="other")]
report = live.analyse(mixed, provoked_at=0, settle_quiet=5)
check("mixed/void", report["voidReason"], "guest identity changed mid-trace")

# -- 9. the owner classifier itself ---------------------------------------
ops = [{"op": "text", "rect": [10, 10, 50, 50]}]
check("owner_of/ink",
      live.owner_of({"rect": {"l": 12, "t": 12, "r": 40, "b": 40}}, ops),
      "ink")
check("owner_of/unknown",
      live.owner_of({"rect": {"l": 200, "t": 200, "r": 240, "b": 240}}, ops),
      "unknown")
check("owner_of/semantic",
      live.owner_of({"rect": {"l": 200, "t": 200, "r": 240, "b": 240},
                     "kind": "pushButton", "title": "OK"}, ops),
      "semantic")
# A typed control with NOTHING to say does not own its rectangle — the
# same rule SceneRenderer.semanticOwnsDisplay applies, and the reason
# Date & Time's radios once rendered as push buttons.
check("owner_of/typed-but-empty",
      live.owner_of({"rect": {"l": 200, "t": 200, "r": 240, "b": 240},
                     "kind": "pushButton"}, ops),
      "unknown")

if FAILURES:
    for failure in FAILURES:
        print("FAIL %s" % failure)
    sys.exit(1)
print("ok: flicker analysis (%d properties)" % (26 + 3))
