#!/usr/bin/env python3
"""Does a HEADLESS caller's walk bind, with nobody asking for scenes?

The anchor plane is claimed by an owner lease. Until 2026-08-07 the
reference layer's walk (`elements` / `observe` / `axtree`) claimed
nothing at all: it read through a plane somebody else was holding up —
the scene, whose ten-second lease is renewed by host traffic only once a
`scene.request` has been served on the link, or the Processes page while
it is visible.

So a caller that only ever walks — an MCP client calling
`now_observe_elements` — had no claim, and every foreign process came
back `bind: no-plane`. With a Mirror polling beside it the same caller
got the intermittent form instead: `no-plane` seconds after a `reveal`,
`ok` on a later poll (docs/open-issues.md, 2026-08-07).

This is the measurement, and its whole discipline is one negative:

    IT NEVER ASKS FOR A SCENE.

Not once, not to "warm up", not at connect. A single `scene.request`
arms the plane under the scene's owner and would make the broken build
pass — which is exactly how this went unnoticed, because every existing
harness asks for scenes. One row per walk:

    walk 1   procs=5 foreign=4 bound=4 no-plane=0  [Finder=ok; ...]

`bound` counts foreign processes whose `bind` is "ok"; `no-plane` counts
the ones the guest could not observe. A fixed build reads no-plane=0 on
the FIRST walk; the broken one reads bound=0 with our own process the
only thing it can see.

    tools/local-observe-plane.py --port 5500 --expect-build 20ba2e29 \\
        --walks 4 --gap 3

Refuses a guest it did not mean to measure: every QEMU guest on this Mac
sees the host as 10.0.2.2, so --expect-build is asserted against the
hello before any number is believed (AGENTS.md).

Scratch instrument, `local-*` like its neighbours: it drives one emulator
clone from one desk and ships to nobody.
"""

import argparse
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts",
                                "probes"))
import nowwire  # noqa: E402


def walk(link, verb="observe"):
    # `command` already returns the reply's `output` object. Unwrapping it
    # a second time is the exact bug that made four ported probe harnesses
    # report empty observations for a day (docs/open-issues.md), so it is
    # spelled once, here, with this comment beside it.
    args = {"scope": "all"} if verb in ("observe", "axtree") else {}
    tree = (link.command(verb, args) or {}).get(verb) or {}
    procs = tree.get("processes") or []
    rows = []
    for p in procs:
        rows.append((p.get("name"), p.get("bind"), bool(p.get("front"))))
    # FOREIGN processes only. Our own always binds — the anchor plane is
    # not involved in reading ourselves — so counting it would let a
    # completely dark plane read as one bound process.
    foreign = [(n, b) for n, b, _ in rows
               if (n or "").strip() != "New Old World"]
    return {
        "procs": len(rows),
        "foreign": len(foreign),
        "bound": sum(1 for _, b in foreign if b == "ok"),
        "noplane": sum(1 for _, b in foreign if b == "no-plane"),
        "rows": rows,
    }


def row(label, r):
    names = "; ".join(f"{n}={b}" for n, b, _ in r["rows"])
    print(f"{label:>10}  procs={r['procs']} foreign={r['foreign']} "
          f"bound={r['bound']} no-plane={r['noplane']}  [{names}]",
          flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    nowwire.add_link_args(ap)
    ap.add_argument("--expect-build", default=None,
                    help="refuse a guest whose hello build is not this")
    ap.add_argument("--walks", type=int, default=4)
    ap.add_argument("--gap", type=float, default=3.0,
                    help="seconds of wire silence between walks")
    ap.add_argument("--verb", default="observe",
                    choices=["elements", "observe", "axtree"])
    a = ap.parse_args()

    link = nowwire.link_from_args(a)
    build = str(link.hello.get("build") or "")
    if a.expect_build and a.expect_build not in build:
        link.close()
        raise SystemExit(
            f"WRONG BUILD: expected {a.expect_build!r}, this guest says "
            f"{build!r}. Refusing to measure — any VM on this Mac can "
            "answer this listener.")
    print(f"guest build: {build}", flush=True)

    # The FIRST walk of a fresh connection is the case that matters most:
    # nothing has been asked for yet, so nothing but this walk itself can
    # have armed anything.
    row("walk 1", walk(link, a.verb))
    for n in range(2, a.walks + 1):
        time.sleep(a.gap)             # silence: no scenes, no verbs
        row(f"walk {n}", walk(link, a.verb))

    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
