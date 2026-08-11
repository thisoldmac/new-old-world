#!/usr/bin/env python3
"""Folder items: does a click computed from an item's reported position select
THAT item?

Ported from `archive/mirror-standalone-2026-08-09/tests/h2-trials.py`, with `h2-scroll.py`'s
question folded in as the `scrolled` case (upstream ran scrolled trials inside
h2-trials.py too, so this is upstream's own structure, not a merge).

UPSTREAM'S RECORDED RESULT: **40/40**, against the Finder's OWN oracle. The
per-trial records are preserved verbatim at
`scripts/probes/upstream/h2-trials-result.json` — 20 unscrolled and 20
scrolled, each naming the item aimed at, the item the Finder said was
selected, and the position it was computed from. That file is the reason this
lane is worth porting even while it cannot run: a future NOW run is directly
comparable to it, trial for trial.

## STATUS ON NOW TODAY: REFUSES — on the click, no longer on the oracle

## The methodology, which is the whole asset

Independence is the part that has burned this project before (the famous "~9
actuations per boot" was an accumulating oracle). So each trial:

  1. clears the Finder's selection and CONFIRMS it is empty;
  2. picks a target the previous trial did not use;
  3. computes the click point from the item's REPORTED position — nothing in
     the probe does that arithmetic, which is the point: the arithmetic under
     test belongs to the thing being measured;
  4. asks the FINDER what is selected. That, not the driver's own report, is
     the oracle. A trial passes only when the Finder names the item aimed at.

Trials are also run against a SCROLLED window, because a scroll moves every
reported position and is the case a saved-grid implementation gets wrong.
That is not a bonus case; it is the case that decides whether items can be
addressed at all.

## The hazard this lane must never forget

**Never a search.** Every script in upstream's H2 lane is scoped to a NAMED
window. A whole-disk Finder search wedged a real machine for ~12 minutes (lab
finding 2026-07-05), and that hazard is why folder-item addressing was never
implemented by hunting for a name. This port keeps the rule: `--folder` names
one folder, and there is no search path in this file at all.

## What this needs from NOW

    script     an AppleScript verb. The oracle is the Finder's own answer to
               `selection` and `position of every item`, and there is no
               substitute — the whole design is that the probe does not
               compute what it is checking. Built in now-guest-ppc/src/input/.
               NOTE its cap: NOW returns 1024 bytes of output, not upstream's
               4096, because NOW's command.result rides a 3072-byte buffer.
               `position of every item` of a large folder can exceed that, and
               the reply says `truncated` when it does — read that row.
    mouseloc   the cursor read every hop calibration closes its loop against.
               Used at line ~236 and, until 2026-07-31, MISSING FROM THIS
               GATE: the harness would have started, run its calibration, and
               died on an unknown-command in the middle of a trial rather
               than refusing cleanly at the top.
    observe    the window's content rect and its scrollbars, for the icon-area
               inset.
    a click    something that puts a real click at a computed point.
               ON AN EMULATOR THIS IS SATISFIED: `--qmp` is required and
               `qmp.click()` at line ~241 is upstream's own mechanism, so
               this harness runs against a QEMU guest today.
               ON METAL IT IS NOT. There is no QMP socket on a real
               Macintosh, upstream used the driver's own dispatch there,
               and NOW has neither a click verb nor a host-side positional
               dispatcher. THAT is the remaining blocker, and it is a
               metal-only one. (Corrected 2026-07-31: this paragraph read
               as though there were no click path at all, while the file
               below required one and called it.)

Usage:

    NOW_METAL=1 python3 scripts/probes/h2-items-probe.py --port 5252 \\
        --folder "Macintosh HD:TimBotTu" --n 20
"""

from __future__ import annotations

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import qmp as qmpmod                                              # noqa: E402
import tally                                                      # noqa: E402
from nowwire import (GuestError, add_link_args, link_from_args,   # noqa: E402
                     refuse_without_metal)

PROBE = "h2-items-probe"
REQUIRED = ("script", "observe", "mouseloc")

# The Finder's icon box: `bounds of` an item is pos..pos+32. From h2calib.py,
# and it is a measured constant of the Finder's icon view, not a guess.
ICON = 32

GATE_NOTE = """\
The oracle is the FINDER'S OWN ANSWER, obtained through an AppleScript verb.
That is not incidental: the whole design is that the probe never computes what
it is checking. `script`, `observe` and `mouseloc` all exist now, and on an
emulator the click does too (`--qmp`). On METAL there is still nothing that
places a real click at a computed point, and without that there is no trial
to score there.

Upstream's recorded 40/40, trial by trial, is preserved at
scripts/probes/upstream/h2-trials-result.json. A NOW run is comparable to it
field-for-field, which is why this harness is checked in unrunnable rather
than rewritten later."""


def script(link, source: str, timeout_ms: int = 20000) -> str:
    """Run AppleScript on the guest and return the text, with OSADoScript's
    source-form quotes stripped.

    Verbatim in behaviour from `h2calib.sc`, including the `osaErr` check —
    an AppleScript that errored returns TEXT, and a probe that read that text
    as an answer would score the error message as a selection.
    """
    out = link.command("script", {"source": source, "timeoutMs": timeout_ms},
                       timeout=timeout_ms / 1000.0 + 10)
    text = link.field(out, "script", "output")
    err = link.maybe_field(out, "script", "osaErr")
    if isinstance(text, str) and len(text) >= 2 \
            and text.startswith('"') and text.endswith('"'):
        text = text[1:-1]
    # `if err:` WOULD ALWAYS FIRE. NOW's x-rowArray is [label, value] STRING
    # pairs by contract, so a clean run reports osaErr as the string "0",
    # which is truthy in Python — upstream's guest sent a JSON number and the
    # port did not carry that across. Every successful script would have
    # raised, and the failure would have looked like a broken script verb.
    try:
        errno = int(str(err), 10) if err not in (None, "") else 0
    except ValueError:
        errno = -1                        # unparseable is not "no error"
    if errno:
        raise GuestError("osaErr", f"{errno}: {text}")
    return text


def window_items(link, folder: str):
    """(content rect, [(name, x, y)...]) for ONE NAMED folder's window.

    Never a search. See the hazard note in the module docstring.
    """
    script(link, f'tell application "Finder"\nopen folder "{folder}"\n'
                 f'end tell')
    time.sleep(1.5)
    raw = script(link,
                 'tell application "Finder"\n'
                 'set w to window 1\n'
                 'set r to bounds of w\n'
                 'set out to (item 1 of r as text) & "," & '
                 '(item 2 of r as text) & "," & (item 3 of r as text) & "," & '
                 '(item 4 of r as text)\n'
                 'repeat with i in (every item of folder of w)\n'
                 'set p to position of i\n'
                 'set out to out & "\\n" & (name of i) & "\\t" & '
                 '(item 1 of p as text) & "," & (item 2 of p as text)\n'
                 'end repeat\n'
                 'return out\n'
                 'end tell')
    lines = raw.replace("\r", "\n").split("\n")
    rect = [int(v) for v in lines[0].split(",")]
    items = []
    for line in lines[1:]:
        if "\t" not in line:
            continue
        name, _, coords = line.partition("\t")
        parts = coords.split(",")
        # A record missing a coordinate is DROPPED, never filled in. Upstream's
        # mutation list names "parse fills in a missing coordinate instead of
        # dropping the record" as a bug it deliberately put back to watch fail.
        if len(parts) != 2:
            continue
        try:
            items.append((name, int(parts[0].strip()), int(parts[1].strip())))
        except ValueError:
            continue
    return rect, items


def deselect(link) -> bool:
    script(link, 'tell application "Finder" to set selection to {}')
    time.sleep(0.4)
    return selection(link) == ""


def selection(link) -> str:
    return script(link,
                  'tell application "Finder"\n'
                  'set s to selection\n'
                  'if (count s) is 0 then return ""\n'
                  'return name of item 1 of s\n'
                  'end tell')


def icon_area(link, rect):
    """The window's content area minus its scrollbars.

    Upstream's mutation list has "iconArea ignores the window's scrollbars (no
    info-bar inset)" as a deliberate bug — so the inset is load-bearing and
    comes from the OBSERVATION's control rects, not from a constant.
    """
    left, top, right, bottom = rect
    for w in link.command("observe", {"scope": "front"}).get("windows", []):
        for c in w.get("controls", []):
            r = c.get("rect")
            if not r or not c.get("visible"):
                continue
            if r[2] - r[0] < 20 and r[2] >= right - 20:      # vertical bar
                right = min(right, r[0])
            if r[3] - r[1] < 20 and r[3] >= bottom - 20:     # horizontal bar
                bottom = min(bottom, r[1])
    return [left, top, right, bottom]


def trial(link, qmp, folder: str, i: int, used: set, scrolled: bool) -> dict:
    if not deselect(link):
        return {"trial": i, "valid": False,
                "why": "the selection would not clear; this trial cannot tell "
                       "its own click from the last one's"}
    rect, items = window_items(link, folder)
    area = icon_area(link, rect)
    fresh = [it for it in items if it[0] not in used]
    if not fresh:
        used.clear()
        fresh = items
    if not fresh:
        return {"trial": i, "valid": False, "why": "the folder has no items"}
    name, ix, iy = fresh[i % len(fresh)]
    used.add(name)

    # The click point, computed from the item's REPORTED position and the
    # icon's own box. Upstream's mutation "clickPoint aims at the icon's
    # top-left, not its centre" is why the +ICON//2 is here rather than
    # implied.
    px = area[0] + ix + ICON // 2
    py = area[1] + iy + ICON // 2
    if not (area[0] <= px < area[2] and area[1] <= py < area[3]):
        return {"trial": i, "item": name, "pos": [ix, iy], "valid": False,
                "why": "the computed point falls outside the icon area"}

    qmpmod.position(lambda: _mouse(link), qmp, px, py)
    qmp.click()
    time.sleep(1.2)

    got = selection(link)
    return {"trial": i, "item": name, "selected": got, "hit": got == name,
            "pos": [ix, iy], "point": [px, py], "scrolled": scrolled,
            "replied": True, "actuated": got == name, "why": ""}


def _mouse(link):
    out = link.command("mouseloc")
    return int(link.field(out, "mouseloc", "x")), \
        int(link.field(out, "mouseloc", "y"))


def run_case(link, qmp, folder: str, n: int, scrolled: bool) -> dict:
    label = "scrolled" if scrolled else "unscrolled"
    if scrolled:
        raise SystemExit(
            "TODO(now): no way to SCROLL a window on NOW's wire.\n"
            "  Upstream dragged the scrollbar over QMP after reading its rect\n"
            "  from axtree. That needs the observation's control rects, which\n"
            "  is the same Wave 2A blocker, so it is named rather than\n"
            "  half-implemented: an unscrolled run reported under the\n"
            "  scrolled case's name would claim the exact thing this case\n"
            "  exists to test.")
    print(f"\n=== folder items, {label}, oracle = the Finder's selection, "
          f"N={n}")
    trials, used = [], set()
    for i in range(n):
        t = trial(link, qmp, folder, i, used, scrolled)
        trials.append(t)
        sys.stdout.write("!" if not t.get("valid", True) else
                         ("." if t.get("hit") else "?"))
        sys.stdout.flush()
    print()
    return tally.rate_summary(label, trials)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--folder", required=True,
                    help="ONE named folder. There is no search path in this "
                         "harness and there must never be one.")
    ap.add_argument("--case", action="append",
                    choices=("unscrolled", "scrolled"))
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    link = link_from_args(args)
    link.require_verbs(PROBE, *REQUIRED, note=GATE_NOTE)
    qmp = qmpmod.Qmp(args.qmp)

    results = [run_case(link, qmp, args.folder, args.n, c == "scrolled")
               for c in (args.case or ["unscrolled", "scrolled"])]
    tally.print_summary(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
    link.close()
    return 0 if all(r["n"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
