#!/usr/bin/env python3
"""Does a QUIET GAP blind the next scene? One row per gap, measured.

The anchor plane is claimed by an owner lease and, before 2026-08-06, only
a `scene.request` renewed it (`peek.c :: kNowPeekOwnerLeaseTicks`, 600
ticks). Stop asking for scenes for longer than that and the next walk
reported `now_no_plane` for every foreign process — NOW's own window and
nothing else — while the machine was unchanged and a modal was open on it
(docs/open-issues.md, "a ten-second gap in scene polling blinds the whole
walk").

This is the measurement, not the argument. For each gap it goes SILENT for
that long, then asks for one WHOLE document and prints what came back:

    gap 20s  windows=3  foreign=2  no-plane=0  [Set Time Zone; Date & Time]

`no-plane` counts foreign processes whose coverage says the guest could not
observe them, which is what a lapsed plane looks like from here. Whole
documents always (`full`), so nothing printed can be a delta artefact.

Two things it is careful about:

  * Silence means silence. During a gap this sends NOTHING — not even a
    command — because any host traffic now renews the claim, which is the
    fix under test. The guest's own keepalive ping is answered on the next
    read, and a `pong` deliberately does not renew.
  * It refuses a guest it did not mean to measure. Every QEMU guest on this
    Mac sees the host as 10.0.2.2, so `--expect-build` is asserted against
    the hello before any number is believed (AGENTS.md).

    tools/local-plane-lapse.py --port 5520 --expect-build 1a2b3c \\
        --gaps 3 8 12 20

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


def observe(link, full=True):
    doc, env = link.scene(full=full)
    wins = doc.get("windows") or []
    procs = doc.get("processes") or []
    ours = None
    for p in procs:
        if (p.get("name") or "").strip() == "New Old World":
            ours = p.get("psn")
    foreign = [w for w in wins if w.get("psn") != ours]
    coverage = (doc.get("meta") or {}).get("coverage") or []
    blind = [c for c in coverage
             if c.get("scope") == "windows"
             and c.get("status") not in ("complete", None)]
    return {
        "seq": doc.get("seq"),
        "digest": env.get("digest") if isinstance(env, dict) else None,
        "windows": len(wins),
        "foreign": len(foreign),
        "blind": len(blind),
        "titles": [w.get("title") for w in wins],
    }


def row(label, r):
    print(f"{label:>10}  seq={r['seq']} digest={r['digest']} "
          f"windows={r['windows']} foreign={r['foreign']} "
          f"not-observed={r['blind']}  {r['titles']}", flush=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    nowwire.add_link_args(ap)
    ap.add_argument("--expect-build", default=None,
                    help="refuse a guest whose hello build is not this")
    ap.add_argument("--gaps", type=float, nargs="*",
                    default=[3, 8, 12, 20],
                    help="seconds of total wire silence before each walk")
    a = ap.parse_args()

    link = nowwire.link_from_args(a)
    build = str(link.hello.get("build") or "")
    if a.expect_build and a.expect_build not in build:
        link.close()
        raise SystemExit(
            f"WRONG BUILD: expected {a.expect_build!r}, this guest says "
            f"{build!r}. Refusing to measure — any VM on this Mac can "
            "answer this listener.")

    # THE FIRST SCENE OF A FRESH CONNECTION is its own case, and it used to
    # be blind for the same reason a gap is: the claim is published and the
    # walk starts before the resident echoes it. Printed, never discarded.
    row("connect", observe(link))

    for gap in a.gaps:
        time.sleep(gap)               # total silence: no verbs, no scenes
        row(f"gap {gap:g}s", observe(link))

    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
