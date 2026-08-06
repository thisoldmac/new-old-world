#!/usr/bin/env python3
"""What a scene costs on the wire, with deltas and without.

The claim scene deltas are built on is a BYTE COUNT, so this measures one:
it asks the same guest for the same machine twice over, once always asking
for a whole document and once quoting the baseline it holds, and prints
what crossed the wire and how long the round trip took each time.

It also watches the walk, because a delta that halves bytes and doubles
walk time is not a win, and nothing else in the run would say so.

    tools/scene-delta-bench.py --port 5441 --build 8b4045 --samples 12

Asserts the guest's build fingerprint before believing anything it says:
every QEMU guest on this Mac sees the host as 10.0.2.2, so any session's
VM running any branch's build can answer this listener (AGENTS.md).
"""

import argparse
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts",
                                "probes"))
import nowwire  # noqa: E402


def summarise(label, rows):
    """One condition's numbers. Medians, because a cooperatively scheduled
    Macintosh produces outliers that a mean would launder."""
    if not rows:
        print(f"{label}: no samples")
        return
    wire = [r["bytes"] for r in rows]
    trip = [r["ms"] for r in rows]
    walk = [r["walkMs"] for r in rows if r["walkMs"] is not None]
    forms = {}
    for r in rows:
        forms[r["form"]] = forms.get(r["form"], 0) + 1
    print(f"{label}:")
    print(f"  forms      {forms}")
    print(f"  wire bytes median={statistics.median(wire):.0f} "
          f"min={min(wire)} max={max(wire)} total={sum(wire)}")
    print(f"  round trip median={statistics.median(trip):.0f}ms "
          f"min={min(trip)}ms max={max(trip)}ms")
    if walk:
        print(f"  walkMs     median={statistics.median(walk):.0f} "
              f"min={min(walk)} max={max(walk)}")
    return {"bytes": statistics.median(wire), "total": sum(wire),
            "ms": statistics.median(trip),
            "walk": statistics.median(walk) if walk else None}


def run(link, samples, use_since, drive=None):
    """One condition. `use_since` chains the baseline the way the host
    does; without it every ask is a cold one.

    `drive` is a list of processes to front, one per sample, so the
    machine is actually CHANGING between walks. An idle measurement
    flatters deltas — every answer is scene.same — and would say nothing
    about the case the product spends its time in."""
    rows = []
    since = None
    for i in range(samples):
        if drive:
            link.command("front", {"target": drive[i % len(drive)]})
        started = time.time()
        doc, env = link.scene(since=since)
        elapsed = int((time.time() - started) * 1000)
        rows.append({"bytes": env.get("bytes") or 0,
                     "ms": elapsed,
                     "walkMs": env.get("walkMs"),
                     "whole": env.get("wholeBytes"),
                     "form": env.get("form")})
        if use_since:
            # A delta and a scene.same both republish the digest of the
            # scene we now hold; a whole document does too. Chaining it is
            # the whole of the host's own policy.
            since = env.get("digest") or since
        _ = doc
    return rows


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=float, default=240.0)
    ap.add_argument("--build", default=None,
                    help="required prefix of the guest's build stamp")
    ap.add_argument("--front", default=None,
                    help="bring this process to the front first")
    ap.add_argument("--samples", type=int, default=10)
    ap.add_argument("--drive", default=None,
                    help="comma-separated processes to front, one per "
                         "sample, so the machine changes between walks")
    args = ap.parse_args()

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = link.hello.get("build", "")
    print(f"guest build: {build}  name={link.hello.get('name')}  "
          f"port={args.port}")
    if args.build and not build.startswith(args.build):
        sys.exit(f"WRONG GUEST: build {build!r} is not the build under test "
                 f"({args.build!r})")
    if args.front:
        print(link.command("front", {"target": args.front}))

    # BEFORE first, so the machine is in the same state for both and the
    # "after" run cannot be credited with a quieter moment.
    drive = args.drive.split(",") if args.drive else None
    before = run(link, args.samples, use_since=False, drive=drive)
    after = run(link, args.samples, use_since=True, drive=drive)

    b = summarise("whole documents (no `since`)", before)
    a = summarise("deltas (`since` chained, as the host does)", after)
    if b and a and b["total"]:
        print(f"\nwire bytes over {args.samples} scenes: "
              f"{b['total']} -> {a['total']} "
              f"({100.0 * a['total'] / b['total']:.1f}% of before)")
        if b["walk"] and a["walk"]:
            print(f"walk median: {b['walk']}ms -> {a['walk']}ms "
                  "(a delta that halves bytes and doubles the walk is not "
                  "a win)")
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
