#!/usr/bin/env python3
"""Where a round trip's time goes when the answer is free.

The deltas arc left one number standing: a scene round trip cost a 115 ms
median even when the answer was a zero-byte "nothing changed". So it was
neither the work (the walk is 3-8 ms) nor the bytes. The remaining
candidate is the WAIT - main.c sleeps six ticks in WaitNextEvent unless a
transfer is already in flight, so a request arriving into an idle
connection sits on the socket until the sleep expires.

That fits the number well enough to be believed, which is exactly the
kind of fit that has been wrong twice in one day on this project. This
does not infer it. It reads the guest's own `wirestat`, which reports two
distributions only the guest can take:

  pass   - the interval between wire service passes
  notice - the delay from Open Transport SAYING data arrived to the loop
           reading it

and pairs them with a host-side clock on the same round trips, so the
three terms - notice, walk, bytes - can be added up and checked against
what the wall clock says.

It sweeps CONDITIONS, all on one boot, because a comparison made across
two boots is a comparison of two machines:

    tools/local-wire-latency.py --port 5470 --build e6ad3c \\
        --conditions base wake sleep1 --drive Finder,New\\ Old\\ World

Scratch instrument, `local-*` like its neighbours: one desk, one
emulator, ships to nobody.
"""

import argparse
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts",
                                "probes"))
import nowwire  # noqa: E402


# name -> (wirestat action line, what it means)
CONDITIONS = {
    "base":   [("sleep", 6), ("wake", "off")],
    "sleep1": [("sleep", 1), ("wake", "off")],
    "sleep3": [("sleep", 3), ("wake", "off")],
    "wake":   [("sleep", 6), ("wake", "on")],
    "wake1":  [("sleep", 1), ("wake", "on")],
}

BLURB = {
    "base":   "as shipped: 6-tick idle sleep, no wake",
    "sleep1": "1-tick idle sleep, no wake",
    "sleep3": "3-tick idle sleep, no wake",
    "wake":   "6-tick sleep, woken by Open Transport",
    "wake1":  "1-tick sleep AND the wake (belt and braces)",
}


def wirestat(link, action=None, value=None):
    args = {}
    if action:
        args["action"] = action
    if value is not None:
        args["value"] = str(value)
    out = link.command("wirestat", args or None)
    return {k: v for k, v in nowwire.GuestLink.rows(out, "wirestat")}


def show(rows, prefix):
    """The histogram as the guest sent it, buckets and all. Printing the
    median alone would throw away the tail, which on a cooperatively
    scheduled Macintosh is the part a person feels."""
    keys = [k for k in rows if k.startswith(prefix + " ")]
    head = [k for k in keys if k.split()[-1] in ("n", "mean", "min", "max")]
    bins = [k for k in keys if k not in head]
    print(f"    {prefix}: " + "  ".join(f"{k.split(' ',1)[1]}={rows[k]}"
                                        for k in head))
    for k in bins:
        print(f"      {k.split(' ', 1)[1]:>22}  {rows[k]}")


def run_condition(link, name, samples, drive, settle, gap):
    print(f"\n== {name}: {BLURB[name]} ==")
    # Both knobs, always, in both conditions: a sweep that only sets what
    # it is changing carries the previous condition's other setting.
    for action, value in CONDITIONS[name]:
        rows = wirestat(link, action, value)
    print(f"     sleep={rows.get('Idle sleep')}  "
          f"wake={rows.get('Wake on data')}  "
          f"notifier={rows.get('Notifier')}")

    # Settle, then reset: the condition change itself relaunches nothing
    # but does cost a command round trip, and its own pass belongs to
    # neither condition.
    time.sleep(settle)
    wirestat(link, "reset")

    # THE CANARY. A shorter sleep or a wake that starves the rest of the
    # Macintosh starves the MIRROR: the anchor plane captures a process's
    # A5 when that process pumps, so a machine given no time reports
    # foreign applications it cannot bind. `apps` carries an `error` per
    # application when the bind failed, so "how many did we actually
    # see into" is readable from the same scene the latency came from.
    trips, walks, byts, bound, wins = [], [], [], [], []
    since = None
    for i in range(samples):
        # THE CONDITION THAT MATTERS. Back-to-back requests never see the
        # idle sleep at all: answering one leaves a queued control frame,
        # conn_wants_fast_pump goes true, and the next request lands in a
        # 1-tick loop. The product's actual cadence is a poll into a
        # QUIET connection, so the quiet has to be reproduced or the
        # instrument measures the one case that was never slow.
        if gap:
            time.sleep(gap)
        if drive:
            link.command("front", {"target": drive[i % len(drive)]})
            # A front is a mutation; without a beat the next scene races
            # the switch and measures a machine mid-change.
            time.sleep(0.2)
        started = time.time()
        doc, env = link.scene(since=since)
        trips.append((time.time() - started) * 1000.0)
        walk = env.get("walkMs")
        if walk is not None:
            walks.append(walk)
        byts.append(env.get("bytes") or 0)
        since = env.get("digest") or since

    # The canary needs WHOLE documents, and the latency samples above are
    # deltas by design - a `scene.same` carries no app list to count. So
    # it is taken separately, after, in the same condition.
    for _ in range(3):
        time.sleep(gap or 0.3)
        doc, _env = link.scene()
        apps = doc.get("apps") or []
        bound.append(sum(1 for a in apps if not a.get("error")))
        wins.append(len(doc.get("windows") or []))

    rows = wirestat(link)
    print(f"    round trip  median={statistics.median(trips):.0f}ms "
          f"min={min(trips):.0f} max={max(trips):.0f}  n={len(trips)}")
    if walks:
        print(f"    walkMs      median={statistics.median(walks):.0f} "
              f"max={max(walks)}")
    print(f"    wire bytes  median={statistics.median(byts):.0f} "
          f"total={sum(byts)}")
    print(f"    notifications={rows.get('Data notifications')}  "
          f"wakes={rows.get('WakeUpProcess calls')}")
    if bound:
        print(f"    CANARY apps bound median={statistics.median(bound):.0f} "
              f"min={min(bound)}   windows median="
              f"{statistics.median(wins):.0f} min={min(wins)}  "
              f"(from {len(bound)} whole documents)")
    show(rows, "pass")
    show(rows, "notice")
    return {"name": name, "trip": statistics.median(trips),
            "walk": statistics.median(walks) if walks else None,
            "bound": statistics.median(bound) if bound else None,
            "wins": statistics.median(wins) if wins else None,
            "rows": rows}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--wait", type=float, default=240.0)
    ap.add_argument("--build", default=None,
                    help="required prefix of the guest's build stamp")
    ap.add_argument("--samples", type=int, default=15)
    ap.add_argument("--settle", type=float, default=2.0)
    ap.add_argument("--gap", type=float, default=1.0,
                    help="seconds of quiet before each request; 0 makes "
                         "every request land in an already-fast loop and "
                         "measures nothing this arc is about")
    ap.add_argument("--front", default=None)
    ap.add_argument("--drive", default=None,
                    help="comma-separated processes to front, one per "
                         "sample: the mid-drive condition")
    ap.add_argument("--conditions", nargs="+", default=["base", "wake"])
    args = ap.parse_args()

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = link.hello.get("build", "")
    print(f"guest build: {build}  name={link.hello.get('name')}  "
          f"port={args.port}")
    if args.build and not build.startswith(args.build):
        sys.exit(f"WRONG GUEST: build {build!r} is not the build under test "
                 f"({args.build!r})")
    if "wirestat" not in link.served_verbs():
        sys.exit("this guest has no `wirestat`: it is not the build under "
                 "test, whatever its stamp says")
    if args.front:
        print(link.command("front", {"target": args.front}))

    # The writer-lease warm-up every instrument in this family needs: the
    # FIRST scene of a fresh connection claims the plane before the
    # resident can echo it, and reports no foreign process at all.
    link.scene()

    drive = args.drive.split(",") if args.drive else None
    results = [run_condition(link, c, args.samples, drive, args.settle,
                             args.gap)
               for c in args.conditions]

    print("\n== round-trip medians ==")
    for r in results:
        print(f"  {r['name']:<8} {r['trip']:6.0f} ms   "
              f"walk {r['walk']} ms   apps bound {r['bound']}   "
              f"windows {r['wins']}")
    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
