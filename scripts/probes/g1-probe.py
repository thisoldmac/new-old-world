#!/usr/bin/env python3
"""Menu titles, the `launch` verb, and the build stamp.

Ported from `timbottu/mirror/tests/g1-probe.py`.

THE ONLY HARNESS IN THIS DIRECTORY THAT CAN PARTLY RUN ON NOW TODAY, and the
one to run first when a machine is available — because it is the cheapest way
to find out whether the ported transport actually talks to a real guest.
Nothing else in this directory can tell you whether the framing, the hello
gate, the keepalive and the rowArray reading work against a Macintosh rather
than against `tools/fakeguest.py` — and its `menus` case is also the cheapest
read of a SCENE there is: one transfer, no armed window, nothing changed on
the machine.

Three unrelated guest truths, each measured against GUEST STATE rather than a
verb's own return value:

  stamp   report the guest's build stamp so a deploy can be confirmed.
          RUNS TODAY. `hello` carries it and NOW's guest sends it unasked.
  launch  launch a real application and require the guest's own process table
          to name it. RUNS TODAY, with a WEAKENED ORACLE — see below.
  menus   dump every menu title and item title of the front app as RAW BYTES,
          so "leading NUL" is an observation and not an inference. Then assert
          that every item is ADDRESSABLE - by the three numbers `menuact`
          takes, which is not what upstream asserted. Reads a SCENE, because
          `observe` reports no menu bar and will not.

## The launch oracle is WEAKER here than upstream, and the difference matters

Upstream required the launched application's WINDOW to appear in `axtree`:
"`ok:true` from the verb proves only that LaunchApplication returned."

This case's oracle is `ps` — the guest's own process table. That is still
guest state and still not the verb's say-so, so the rule is not broken. But it
is a weaker claim, in a specific and knowable way:

    a process appears in `ps` from the moment it EXISTS.
    a window appears when the application has finished opening.

So a `launch` that returns, registers a process, and then dies or hangs before
drawing anything counts as actuated here and would NOT have counted upstream.
Any number this case produces must be reported as "launch/ps", never compared
directly against upstream's "launch/window". `observe` and `axtree` ARE served
now, so re-pointing this at a window is possible and has not been done; when
it is, the case must be RE-RUN rather than back-filled.

This is called out here, in the file, rather than in a report, because the
person who will compare the two tables is reading this file.

## What this needs from NOW

    menus case:   the SCENE PLANE - `scene.request`, answered as a transfer.
                  Not a verb, so no verb gate can check it; the case asks and
                  refuses by name if nothing answers.
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
import scene as scenelib                                          # noqa: E402
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
    # No verb. The menu bar comes from a SCENE, which is a typed control
    # message and appears in no verb list - so this case's gate is
    # `require_scene_plane`, on its own fetch, not a row here.
    "menus": (),
}

GATE_NOTE = """\
The `launch` case needs the guest's own process table to name what it
launched: `launch` to do it and `ps` to see it.

The other two cases need no verb at all - `stamp` reads the hello the guest
sent unasked, and `menus` reads a scene."""

SCENE_GATE_NOTE = """\
The `menus` case is what needs it, and only that case. It walks the front
application's menu bar, which `observe` does not report and deliberately will
not (docs/streaming-a-scene.md: a tree is a TRANSFER, and
src/scene/scene_walk.c already ships the bar over scene.request).

The other two cases of this probe do not touch a scene: try
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

    ONE SCENE, for the whole case. That is the entire fetch policy here and it
    needs no rule: this case has no trial loop and no armed window — it reads
    the bar once and describes it. (The no-hijack probe's menu cases DO have a
    trial loop, and where their fetch sits is argued in scripts/probes/scene.py.)

    The raw-bytes part is the point and is why this cannot be satisfied by a
    prettier reader: upstream found leading NULs in menu titles, and a
    decode-and-strip reader would have turned that observation into an
    inference. What is reported here is what the walk read — and it survives
    the crossing intact, because the guest's escaper turns a high or control
    MacRoman byte into `\\uXXXX` for its real Unicode value, which re-encodes
    to the same byte here.

    Then the assertion: every item is ADDRESSABLE. A menu system that reports
    an item nothing can be addressed by has reported decoration.

    WHAT "ADDRESSABLE" MEANS IS NOT UPSTREAM'S. Mirror's `menuinvoke` took a
    per-item reference, so upstream asserted `item.ref`. NOW's `menuact` takes
    three numbers — the menu's `id`, the item's 1-based position, and the
    menu title's `left` as the act's identity check — and the scene reports
    exactly those and no `ref` at all. So the assertion is re-derived against
    the verb this project actually serves rather than transcribed. It is a
    DIFFERENT claim from upstream's and must not be tabled beside it as the
    same one.
    """
    doc, env = link.require_scene_plane(PROBE, note=SCENE_GATE_NOTE)
    print(f"    scene #{env.get('seq')}: {env.get('bytes')} bytes, walk "
          f"{env.get('walkMs')}ms, source {env.get('source')!r}")
    for err in scenelib.scene_errors(doc):
        print(f"      scene says: {err}")

    state = scenelib.menubar_state(doc)
    if state == scenelib.ABSENT:
        raise SystemExit(
            "PRECONDITION FAILED: this scene reports NO MENU BAR. Absent is "
            "not empty — the producer retracts the whole plane when the front "
            "process's menu list does not parse, rather than ship a short "
            "one, and meta.errors above says so. Reporting 0/0 here would "
            "claim a machine has no menus when nothing looked.")
    print(f"    menu bar of {scenelib.menubar_app(doc)!r}: {state}")

    trials = []
    for m in scenelib.menus(doc):
        title = m.get("title")
        raw = title.encode("mac_roman", "replace") if isinstance(title, str) \
            else b""
        print(f"    menu {m.get('id')} {title!r} raw={raw!r} "
              f"left={m.get('left')}")
        try:
            items = scenelib.menu_items(m)
        except scenelib.PlaneAbsent:
            # This menu's item walk did not complete, so the producer dropped
            # its `items` rather than ship a short list. NOT an empty menu,
            # and NOT a trial: there is nothing here to have been addressable.
            print("        (this menu reports no item list — its walk did not "
                  "complete. Absent, not empty.)")
            continue
        if not items:
            print("        (no items: the walk ran and this menu has none)")
        for item in items:
            it = item.get("title")
            iraw = it.encode("mac_roman", "replace") if isinstance(it, str) \
                else b""
            leading_nul = iraw.startswith(b"\x00")
            index = item.get("index")
            # The three numbers `menuact` requires, all of them present and
            # sane. Nothing here calls the verb — this case names what could
            # be addressed, it does not act.
            addressable = (isinstance(m.get("id"), int)
                           and isinstance(m.get("left"), int)
                           and isinstance(index, int) and index >= 1)
            if leading_nul:
                print(f"        !! leading NUL in {iraw!r}")
            trials.append({"menu": title, "menuId": m.get("id"),
                           "item": it, "index": index, "raw": repr(iraw),
                           "separator": item.get("separator"),
                           "enabled": item.get("enabled"),
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
