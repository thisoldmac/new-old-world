#!/usr/bin/env python3
"""Menu titles, the `launch` verb, and the build stamp.

Ported from `timbottu/mirror/tests/g1-probe.py`.

THE ONLY HARNESS IN THIS DIRECTORY THAT CAN PARTLY RUN ON NOW TODAY, and the
one to run first when a machine is available — because it is the cheapest way
to find out whether the ported transport actually talks to a real guest. Every
other harness here is blocked behind `observe`, and none of them can tell you
whether the framing, the hello gate, the keepalive and the rowArray reading
work against a Macintosh rather than against `tools/fakeguest.py`.

Three unrelated guest truths, each measured against GUEST STATE rather than a
verb's own return value:

  stamp   report the guest's build stamp so a deploy can be confirmed.
          RUNS TODAY. `hello` carries it and NOW's guest sends it unasked.
  launch  launch a real application and require the guest's own process table
          to name it. RUNS TODAY, with a WEAKENED ORACLE — see below.
  menus   dump every menu title and item title of the front app as RAW BYTES,
          so "leading NUL" is an observation and not an inference. Then assert
          that every item is addressable by its reported title.
          REFUSES: needs `observe`.

## The launch oracle is WEAKER here than upstream, and the difference matters

Upstream required the launched application's WINDOW to appear in `axtree`:
"`ok:true` from the verb proves only that LaunchApplication returned."

NOW has no `axtree` and no `observe`, so the strongest oracle available on
today's wire is `ps` — the guest's own process table. That is still guest
state and still not the verb's say-so, so the rule is not broken. But it is a
weaker claim, in a specific and knowable way:

    a process appears in `ps` from the moment it EXISTS.
    a window appears when the application has finished opening.

So a `launch` that returns, registers a process, and then dies or hangs before
drawing anything counts as actuated here and would NOT have counted upstream.
Any number this case produces must be reported as "launch/ps", never compared
directly against upstream's "launch/window", and the day `observe` lands this
case should be re-pointed at a window and RE-RUN rather than back-filled.

This is called out here, in the file, rather than in a report, because the
person who will compare the two tables is reading this file.

## What this needs from NOW

    menus case:   observe        (Wave 2A of docs/mirror-foldin-inventory.md)
    launch case:  nothing        - `launch` and `ps` are both wire-served
    stamp case:   nothing        - `hello` carries the build

Usage:

    NOW_METAL=1 python3 scripts/probes/g1-probe.py --port 5252 --case stamp
    NOW_METAL=1 python3 scripts/probes/g1-probe.py --port 5252 --case launch \\
        --app "Macintosh HD:Applications (Mac OS 9):SimpleText"
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

PROBE = "g1-probe"

# Upstream's target. Kept as the default so a run here and a run there are
# launching the same application; overridable because NOW's fleet is not one
# machine and the path differs on a 68K System 7.1 volume.
SIMPLETEXT = "Macintosh HD:Applications (Mac OS 9):SimpleText"

REQUIRED = {
    "stamp": (),
    "launch": ("launch", "ps"),
    "menus": ("observe",),
}

GATE_NOTE = """\
The `menus` case walks the menu bar of the front application and asserts every
item is addressable by its reported title. It needs an observation to walk.

The other two cases of this probe DO run on this guest: try
`--case stamp` and `--case launch`."""


def case_stamp(link) -> dict:
    """The build stamp, and whether the machine agrees with itself.

    Upstream read it from a `hello` verb it called. NOW's guest sends hello
    unasked as the first thing on the link, so it is already in hand — and
    `vers` is asked as well, because a guest whose hello stamp and whose
    `vers` disagree has been half-updated, which is a deploy failure that
    looks exactly like a working machine.
    """
    hello = link.hello
    print(f"    name     {hello.get('name')!r}")
    print(f"    version  {hello.get('version')!r}")
    print(f"    build    {hello.get('build')!r}")
    print(f"    os       {hello.get('os')!r}")
    print(f"    agent    {hello.get('agent')!r}   (consent tier)")
    row = {"trial": 1, "helloVersion": hello.get("version"),
           "helloBuild": hello.get("build"), "replied": True}
    try:
        out = link.command("vers")
        rows = link.rows(out, "vers")
        row["vers"] = rows
        print(f"    vers     {rows}")
        # Agreement is the actuation: a stamp read one way is a reading, two
        # readings that agree is a fact about the machine.
        flat = " ".join(str(c) for r in rows for c in r)
        row["actuated"] = bool(hello.get("version")
                               and str(hello["version"]) in flat)
        if not row["actuated"]:
            print("    !! hello's version does not appear in `vers` — this "
                  "machine may be half-deployed")
    except GuestError as exc:
        row["actuated"] = False
        row["error"] = exc.code
        print(f"    vers     refused: {exc}")
    return tally.rate_summary("stamp", [row])


def case_launch(link, app: str, n: int) -> dict:
    """Launch by path, and require the GUEST's process table to name it.

    Read the module docstring before quoting any number this produces: the
    oracle is `ps`, not a window, and that is a weaker claim than upstream's.

    Independence between trials: the application is quit between them, because
    launching an already-running application is a different operation with a
    different answer, and a probe that measured nineteen no-ops after one real
    launch would report 20/20 for a verb that worked once.
    """
    name = app.rsplit(":", 1)[-1]
    print(f"\n=== launch {name!r} by path, oracle = the guest's `ps`, N={n}")
    trials = []
    for i in range(n):
        # Reset. `quit` is wire-served; an app that will not quit makes the
        # trial invalid rather than failed, because it was never launched by
        # this trial.
        if oracles.is_running(link, name):
            try:
                link.command("quit", line=name, timeout=40)
            except GuestError:
                pass
            time.sleep(3.0)
        if oracles.is_running(link, name):
            trials.append({"trial": i + 1, "valid": False,
                           "why": f"{name} would not quit; this trial could "
                                  f"not launch it"})
            sys.stdout.write("!")
            sys.stdout.flush()
            continue

        replied = actuated = False
        code = None
        try:
            link.command("launch", {"target": app}, timeout=60)
            replied = True
        except GuestError as exc:
            replied = True             # rule 2: ok:false IS a reply
            code = exc.code
        except TimeoutError:
            replied = False

        # The guest's own answer, after a settle. Not the verb's.
        for _ in range(20):
            time.sleep(1.0)
            if oracles.is_running(link, name):
                actuated = True
                break

        trials.append({"trial": i + 1, "app": app, "replied": replied,
                       "actuated": actuated, "error": code,
                       "oracle": "ps"})
        sys.stdout.write("." if actuated else ("~" if replied else "?"))
        sys.stdout.flush()
    print()
    return tally.rate_summary("launch", trials)


def case_menus(link) -> dict:
    """Every menu title and item title of the front app, as RAW BYTES.

    The raw-bytes part is the point and is why this cannot be satisfied by a
    prettier reader: upstream found leading NULs in menu titles, and a
    decode-and-strip reader would have turned that observation into an
    inference. What is reported here is what the walk read.

    Then the assertion: every item is ADDRESSABLE by its reported title. A
    menu system that reports a title nothing can be addressed by has reported
    decoration.
    """
    out = link.command("observe", {"scope": "front"})
    menus = out.get("menus") or []
    if not menus:
        raise SystemExit("PRECONDITION FAILED: no menus in the observation")
    trials = []
    for m in menus:
        title = m.get("title")
        raw = title.encode("mac_roman", "replace") if isinstance(title, str) \
            else b""
        print(f"    menu {m.get('id')} {title!r} raw={raw!r} "
              f"left={m.get('left')}")
        for item in m.get("items", []):
            it = item.get("title")
            iraw = it.encode("mac_roman", "replace") if isinstance(it, str) \
                else b""
            leading_nul = iraw.startswith(b"\x00")
            addressable = bool(item.get("ref"))
            if leading_nul:
                print(f"        !! leading NUL in {iraw!r}")
            trials.append({"menu": title, "item": it, "raw": repr(iraw),
                           "leadingNul": leading_nul, "replied": True,
                           "actuated": addressable})
    return tally.rate_summary("menus", trials)


def main() -> int:
    ap = argparse.ArgumentParser(
        description=__doc__,
        formatter_class=argparse.RawDescriptionHelpFormatter)
    add_link_args(ap)
    ap.add_argument("--case", action="append", choices=tuple(REQUIRED))
    ap.add_argument("--app", default=SIMPLETEXT)
    ap.add_argument("--n", type=int, default=20)
    ap.add_argument("--json")
    args = ap.parse_args()

    refuse_without_metal(PROBE)
    cases = args.case or ["stamp", "launch", "menus"]

    link = link_from_args(args)
    needed = sorted({v for c in cases for v in REQUIRED[c]})
    if needed:
        link.require_verbs(PROBE, *needed, note=GATE_NOTE)

    results = []
    for case in cases:
        if case == "stamp":
            results.append(case_stamp(link))
        elif case == "launch":
            results.append(case_launch(link, args.app, args.n))
        elif case == "menus":
            results.append(case_menus(link))

    tally.print_summary(results)
    if args.json:
        with open(args.json, "w") as fh:
            json.dump({"guest": link.hello, "results": results}, fh, indent=2)
        print(f"wrote {args.json}")
    link.close()
    # Not a hijack probe: nothing here is a finding that gates another lane, so
    # the status reports whether the run could measure at all.
    return 0 if all(r["n"] for r in results) else 1


if __name__ == "__main__":
    raise SystemExit(main())
