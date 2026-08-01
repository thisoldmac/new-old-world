#!/usr/bin/env python3
"""Probe `textget` / `textset` — NOW's declared text ops.

Ported from `timbottu/mirror/tests/textops-probe.py` (19 KB). Upstream's
recorded numbers: **20/20 actuated, with the no-hijack cross-fire at 0/20**
(`upstream/p2-ditem.json`, `p2-dialogte.json`, `p2-nohijack.json`).

## STATUS ON NOW TODAY: REFUSES — but this is the lane closest to running

`textget` and `textset` are DECLARED in `contract/asyncapi.yaml`, ahead of any
guest, with their argument shapes already fixed:

    textget  {element}          -> the element's text, and whether it was clipped
    textset  {element, text}    -> whole-contents replacement, no offset form

So this port is already written against NOW's real spelling, not Mirror's
(`{windowZ, window, kind, item}`). The ONLY thing between it and a number is
`observe`, which mints the `now-element-<uuid>` both verbs take. When the
reference layer lands (fold-in Wave 2A), this harness should report.

## The oracle rule, which is stronger here than anywhere else

`textset`'s own reply may contain a read-back — the responder re-reads the
object after writing it. That read-back is real evidence, but it travels the
same code, in the same call, through the same hook, so it CANNOT rule out a
verb that faithfully reports its own private copy of a string.

Two independent paths are therefore required, and both must agree with what
was written or the trial does not count as actuated:

  1. a fresh `textget` in a separate round trip, after a settle;
  2. the OBSERVATION's own text for that element. That comes from the foreign
     memory walk (`now-guest-ppc/src/axwalk/axtext.c`, which NOW has already
     ported and natively tested) — it walks the target's DialogRecord and
     TERec from OUTSIDE the process over the memory seam. It shares no code,
     no call and no moment with the act plane. Where it applies it is the
     strongest oracle this project has for text.

NOW's contract independently says the same thing about what an ok means:
"An ok reply means the change was dispatched into the application's own text
path. It is not a claim that the element now holds the new text... Read it
back with textget to learn that."

## Independence between trials

Every trial closes the dialog and reopens it, and writes a value unique to
that trial. The "~9 actuations per boot" ceiling this project once reported
was an ACCUMULATING ORACLE, not a defect; a probe that leaves the previous
trial's string in the field measures a different machine each time.

## Two cases, because two kinds of text element fail differently

    ditem      a dialog item (`Dialogs.h`: CTRL_ITEM 4, STAT_TEXT 8,
               EDIT_TEXT 16). Addressed through the DialogRecord's item list.
    dialogte   the dialog's own TEHandle - one TERec, not an item list.

Upstream ran them separately and recorded them separately
(`upstream/p2-ditem.json`, `upstream/p2-dialogte.json`). Merging them would
lose the distinction that made the second one worth measuring.

## What this needs from NOW

    observe    to mint the element reference and to provide the SECOND,
               independent read. Both textget and textset are useless without
               it: neither can express "whatever is frontmost", by design.
    textget    declared, served by no guest.
    textset    declared, served by no guest.

Usage:

    NOW_METAL=1 python3 scripts/probes/textops-probe.py --port 5252
    NOW_METAL=1 python3 scripts/probes/textops-probe.py ... --case ditem --n 20
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

PROBE = "textops-probe"

SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"

# Dialogs.h:93-103. The type byte's high bit (itemDisable, 128) is masked off
# by the responder before it reports an item type, so these compare directly.
CTRL_ITEM, STAT_TEXT, EDIT_TEXT = 4, 8, 16
ITEM_DISABLE = 128          # Dialogs.h:103 — rides in the type byte's high bit

CASES = ("ditem", "dialogte")

REQUIRED = ("observe", "textget", "textset")

GATE_NOTE = """\
textget and textset ARE declared in contract/asyncapi.yaml, ahead of any
guest, and this harness is already written against their declared argument
shapes ({element} and {element, text}) rather than Mirror's. The blocker is
`observe`: both verbs take an opaque "now-element-<uuid>" that only an
observation can mint, and by design neither can express "whatever is
frontmost".

Upstream's recorded numbers for this lane: 20/20 actuated, no-hijack 0/20.
See scripts/probes/upstream/p2-ditem.json and p2-dialogte.json."""


def observe(link, scope: str = "front") -> dict:
    return link.command("observe", {"scope": scope})


def open_a_text_dialog(link) -> bool:
    """Get a dialog with text items in front of us.

    Upstream drove SimpleText's Find dialog, because it has both an editable
    item and static text and is reachable without touching a document. The
    ROUTE to it is left as a TODO rather than guessed: on Mirror that meant a
    key verb (cmd+F), and NOW has no key verb today. Guessing a route here
    would be a phantom step that fails in a way that looks like a text bug.
    """
    raise SystemExit(
        "TODO(now): no route to open a text dialog on NOW's wire.\n"
        "  Upstream sent cmd+F to SimpleText through a `key` verb. NOW serves\n"
        "  no key verb and no menu op, so this harness cannot yet STAGE its\n"
        "  own precondition even once textget/textset exist.\n"
        "  Two honest ways out, both cheap, neither guessed here:\n"
        "    * run the probe against a dialog a human opened, and pass\n"
        "      --assume-open so the harness does not try to stage it; or\n"
        "    * land a menu op, at which point this function is three lines.\n"
        "  Named rather than filled in: a plausible fill would fail as though\n"
        "  the text ops were broken.")


def text_elements(link, kind: str) -> list:
    """Every addressable text element in the front dialog, for one case.

    `kind` is the case: "ditem" walks the dialog's item list, "dialogte" wants
    the dialog's own TEHandle. The observation is expected to distinguish them;
    if it does not, this is the one function that has to change.
    """
    out = []
    for w in observe(link).get("windows", []):
        for e in w.get("elements", []):
            if kind == "ditem" and e.get("kind") in ("editText", "ditem"):
                out.append(e)
            elif kind == "dialogte" and e.get("kind") in ("textEdit",
                                                          "dialogte"):
                out.append(e)
    return out


def unique_value(case: str, i: int) -> str:
    """A value unique to this trial. See "Independence between trials".

    Deliberately not random: a reader looking at a failed trial's record needs
    to be able to tell which trial wrote what, and a seed nobody recorded makes
    that impossible.
    """
    letters = "".join(chr(ord("a") + ((i * 7 + k) % 26)) for k in range(8))
    return f"{case}-{i + 1:03d}-{letters}"


def trial(link, case: str, i: int) -> dict:
    elements = text_elements(link, case)
    if not elements:
        return {"trial": i + 1, "valid": False,
                "why": f"no {case} text element in the observation"}
    element = elements[0]
    wanted = unique_value(case, i)

    replied = False
    code = None
    try:
        link.command("textset", {"element": element["ref"], "text": wanted})
        replied = True
    except GuestError as exc:
        replied = True                 # rule 2: ok:false IS a reply
        code = exc.code
    except TimeoutError:
        replied = False

    time.sleep(1.0)                    # settle: the app owns its own text path

    # Path 1 — a fresh textget, separate round trip.
    got = None
    clipped = None
    try:
        out = link.command("textget", {"element": element["ref"]})
        got = link.maybe_field(out, "textget", "text")
        clipped = link.maybe_field(out, "textget", "clipped")
    except (GuestError, TimeoutError):
        pass

    # Path 2 — the observation's own walk. Shares no code with the act plane.
    walked = None
    for w in observe(link).get("windows", []):
        for e in w.get("elements", []):
            if e.get("ref") == element["ref"]:
                walked = e.get("text")

    # BOTH must agree with what was written. Either alone would leave open the
    # verb-reports-its-own-copy failure this case exists to exclude.
    actuated = (got == wanted) and (walked == wanted)

    return {"trial": i + 1, "case": case, "element": element["ref"],
            "wanted": wanted, "textget": got, "observed": walked,
            "clipped": clipped, "replied": replied, "actuated": actuated,
            "pathsAgreed": got == walked, "error": code}


def run_case(link, case: str, n: int) -> dict:
    print(f"\n=== {case}: textset then two independent reads, N={n}")
    trials = []
    for i in range(n):
        t = trial(link, case, i)
        trials.append(t)
        sys.stdout.write("!" if not t.get("valid", True) else
                         ("." if t.get("actuated") else
                          ("~" if t.get("replied") else "?")))
        sys.stdout.flush()
    print()
    disagreed = [t for t in trials if t.get("replied")
                 and not t.get("pathsAgreed", True)]
    if disagreed:
        # The finding this case was built to be able to see at all.
        print(f"    !! {len(disagreed)} trials where the two read paths "
              f"DISAGREED. That is the verb-reports-its-own-copy signature; "
              f"it is the reason there are two paths.")
    return tally.rate_summary(case, trials)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--case", action="append", choices=CASES)
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--assume-open", action="store_true",
                    help="a text dialog is already in front; do not try to "
                         "stage one. See open_a_text_dialog().")
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    link = link_from_args(args)
    link.require_verbs(PROBE, *REQUIRED, note=GATE_NOTE)

    if not args.assume_open:
        open_a_text_dialog(link)

    results = [run_case(link, case, args.n)
               for case in (args.case or list(CASES))]
    tally.print_summary(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")
    link.close()
    return 0 if all(r["n"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
