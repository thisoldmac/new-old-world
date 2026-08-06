#!/usr/bin/env python3
"""Time one guest's scene walk, N times, in one front-process condition.

Reads the breakdown the scene now carries permanently: `meta.phases`,
microseconds per phase, plus the measurement's own weight. It listens as a
host, takes ONE dialling guest, and asserts the build fingerprint it was
told to expect (AGENTS.md: every QEMU guest on this Mac sees 10.0.2.2, so
any session's VM can answer), optionally brings a process to the front.

    tools/local-scene-bench.py --port 5410 --build 9ed6e7 --front Finder
"""

import argparse
import os
import statistics
import sys

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts",
                                "probes"))
import nowwire  # noqa: E402

# The monkey-patch that lived here is gone: nowwire now takes its revision
# from contract/wire_limits.py, which is the one place it is declared. An
# instrument overriding it would be declaring a revision of its own, which
# is exactly what WireLimitsAgreementTests bans and how this drifted before.

# The guest's own order, which is the order the walk runs in. Sorting by
# cost would reorder the columns between conditions and make two runs
# uncomparable at a glance, which is the whole use of the table.
ORDER = ["enumerate", "bind", "windows", "controls", "menubar",
         "semantics", "refs", "encode"]


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=float, default=180.0)
    ap.add_argument("--build", default=None,
                    help="required prefix of the guest's build stamp")
    ap.add_argument("--front", default=None,
                    help="bring this process to the front first")
    ap.add_argument("--samples", type=int, default=5)
    args = ap.parse_args()

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = link.hello.get("build", "")
    print(f"guest build: {build}  name={link.hello.get('name')}")
    if args.build and not build.startswith(args.build):
        sys.exit(f"WRONG GUEST: build {build!r} is not the build under test "
                 f"({args.build!r})")

    if args.front:
        print(link.command("front", {"target": args.front}))

    lat = []
    totals = {name: [] for name in ORDER}
    for i in range(args.samples):
        doc, env = link.scene()
        meta = doc.get("meta", {})
        lat.append(meta.get("latencyMs"))
        procs = doc.get("processes", [])
        front = next((p.get("name") for p in procs if p.get("front")), "?")
        bar = doc.get("menubar") or {}
        menus = bar.get("menus", [])
        wins = doc.get("windows") or []
        ctls = sum(len(w.get("controls") or []) for w in wins)
        print(f"[{i}] front={front!r} latencyMs={meta.get('latencyMs')} "
              f"walkMs={env.get('walkMs')} procs={len(procs)} "
              f"windows={len(wins)} controls={ctls} menus={len(menus)} "
              f"items={sum(len(m.get('items', [])) for m in menus)}")
        phases = meta.get("phases")
        if phases is None:
            print("     (this producer does not report phases)")
            continue
        us = phases.get("us", {})
        for name in ORDER:
            totals[name].append(us.get(name, 0))
        print("     " + "  ".join(f"{n}={us.get(n)}" for n in ORDER))
        print(f"     [cost] clockReads={phases.get('clockReads')} "
              f"clockUs={phases.get('clockUs')} "
              f"faults={phases.get('faults')} "
              f"sum={sum(us.values())}")
    print(f"latencyMs: {sorted(lat)}  median={statistics.median(lat)}")
    if any(totals[name] for name in ORDER):
        print("median us: " + "  ".join(
            f"{n}={statistics.median(totals[n])}" for n in ORDER
            if totals[n]))
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
