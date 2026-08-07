#!/usr/bin/env python3
"""What would N simultaneous window interiors actually cost the resident?

Slice C of plan 019 asks a decision question — is one live interior at a
time the product, or does the contract change — and the brief's first rule
is MEASURE, do not reason. This instrument takes the three readings that
source alone cannot give:

  1. **The port-table budget.** `kNowContentMaxPorts` is 16 rows, shared
     between armed WINDOWS and the offscreen GWorlds hooked at birth that
     make composites joinable. If a real application already spends most of
     16 on worlds, an N-window arm is capped far below 16 and the number
     matters more than the constant does.

  2. **What a retarget costs the window it leaves.** Arming window B of the
     same process runs `content_uninstall_context`, so window A's rows go
     back. This reads `hookedPorts` either side of the switch instead of
     inferring it from `now_content_gne`.

  3. **The arm handshake for a SECOND window of an ALREADY-ARMED process**,
     which the 2026-08-06 arm-latency table never took — every row there is
     a first arm into a fresh target.

Refuses a guest it did not mean to measure (`--expect-build`), because
every QEMU guest on this Mac sees the host as 10.0.2.2 and any session's VM
can answer this listener (AGENTS.md).

Scratch instrument, `local-*` like its neighbours: one emulator clone, one
desk, ships to nobody.
"""

import argparse
import json
import os
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts",
                                "probes"))
import nowwire  # noqa: E402

POLL_BUDGET = 20.0


def status(link):
    return link.command("qdtrace", {"op": "status"}).get("qdtrace") or {}


def arm(link, psn, addr, budget=POLL_BUDGET):
    """Request one arm; return (outcome, seconds, status-at-settle).

    Timed from the `start` reply to the first `status` reporting that
    generation live, which is the same definition tools/local-arm-latency.py
    uses — so the numbers are comparable to the 2026-08-06 table.
    """
    hi, lo = (int(x) for x in psn.split("."))
    started = time.time()
    reply = link.command("qdtrace", {
        "op": "start", "serialHi": hi, "serialLo": lo,
        "window": "0x%08x" % addr, "mode": "record", "ttlTicks": 36000,
    })
    qd = reply.get("qdtrace") or {}
    if not qd.get("requested"):
        return "refused:%s" % (qd.get("code") or "unknown"), None, {}
    want = qd.get("generation")
    deadline = started + budget
    while time.time() < deadline:
        st = status(link)
        act = st.get("active") or {}
        if act.get("generation") == want and act.get("a5") not in (None,
                                                                  "0x00000000"):
            return "armed", time.time() - started, st
        time.sleep(0.05)
    return "timeout", None, status(link)


def occupancy(st):
    act = st.get("active") or {}
    qde = st.get("qdext") or {}
    life = st.get("lifecycle") or {}
    ring = st.get("ring") or {}
    return {
        "hookedPorts": act.get("hookedPorts"),
        "activeWindow": act.get("window"),
        "generation": act.get("generation"),
        "born": qde.get("born"),
        "died": qde.get("died"),
        "bornMissed": qde.get("bornMissed"),
        "arms": life.get("arms"),
        "redrawRequests": life.get("redrawRequests"),
        "redrawServices": life.get("redrawServices"),
        "writeCursor": ring.get("writeCursor"),
    }


def rotate(link, wins, rounds, dwell):
    """ROUND-ROBIN, priced. Option (b) of slice C is "rotate the arm across
    the visible windows within one TTL", and its cost is not the handshake:
    every arm bumps the generation, drops every offscreen-world row this
    context held (`content_uninstall_context`), and issues an
    InvalWindowRect at the newly armed window. So a rotation is a forced
    repaint of a real application's window, at the rotation rate, forever.

    This counts the repaints and the ring bytes the rotation itself spends.
    """
    first = occupancy(status(link))
    print("\nrotation: %d rounds x %d windows, %.1fs dwell" %
          (rounds, len(wins), dwell))
    t0 = time.time()
    for r in range(rounds):
        for w in wins:
            out, secs, _ = arm(link, w["psn"], w["addr"])
            print("  r%d %-16r %-8s %s" % (
                r, (w.get("title") or "")[:16], out,
                "" if secs is None else "%.0f ms" % (secs * 1000)))
            time.sleep(dwell)
    last = occupancy(status(link))
    elapsed = time.time() - t0
    delta = {k: (last[k] - first[k])
             for k in ("arms", "redrawRequests", "redrawServices",
                       "writeCursor")
             if isinstance(last.get(k), int) and isinstance(first.get(k), int)}
    delta["seconds"] = round(elapsed, 1)
    delta["ringBytesPerSecond"] = (round(delta.get("writeCursor", 0) / elapsed)
                                   if elapsed else None)
    print("  over %.0fs: %s" % (elapsed, delta))
    return {"first": first, "last": last, "delta": delta}


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    nowwire.add_link_args(ap)
    ap.add_argument("--expect-build", default=None,
                    help="refuse any guest whose hello build does not contain "
                         "this. Every VM on this Mac can answer this "
                         "listener, so a number from an unasserted guest is "
                         "a number about an unknown build (AGENTS.md).")
    ap.add_argument("--settle", type=float, default=6.0,
                    help="seconds to let the armed window draw before reading")
    ap.add_argument("--rounds", type=int, default=5,
                    help="round-robin rounds to price option (b); 0 skips")
    ap.add_argument("--dwell", type=float, default=2.0,
                    help="seconds each window holds the arm in a rotation")
    ap.add_argument("--json", help="write the readings here")
    args = ap.parse_args()

    link = nowwire.link_from_args(args)
    build = str(link.hello.get("build") or "")
    if args.expect_build and args.expect_build not in build:
        link.close()
        raise SystemExit(
            "WRONG BUILD: expected %r, this guest says %r. Refusing to "
            "measure — any VM on this Mac can answer this listener."
            % (args.expect_build, build))
    print("guest build: %s" % build, flush=True)
    try:
        # `scene` is a message type, not an x-command; only qdtrace is a verb.
        link.require_verbs("multiwindow-cost", "qdtrace")
        # The FIRST scene of a fresh connection claims the plane and reads
        # arm_active before the resident's next jGNE pass can echo it, so it
        # reports no foreign process at all. Warm once, then walk for real.
        link.scene()
        time.sleep(1.5)
        scene = (link.scene() or ({}, {}))[0] or {}
        wins = [w for w in (scene.get("windows") or []) if w.get("addr")]

        by_psn = {}
        for w in wins:
            by_psn.setdefault(w.get("psn"), []).append(w)
        print("scene: %d windows with an exact address, across %d processes"
              % (len(wins), len(by_psn)))
        for psn, ws in sorted(by_psn.items()):
            print("  psn %-14s %d window(s): %s" % (
                psn, len(ws),
                ", ".join("%r@0x%08x" % (w.get("title") or "", w["addr"])
                          for w in ws)))

        multi = [(p, ws) for p, ws in by_psn.items() if len(ws) >= 2]
        readings = {"windows": len(wins), "processes": len(by_psn),
                    "multiWindowProcesses": len(multi), "rows": []}

        # Reading 1+3: arm the front window, settle, read occupancy.
        front = next((w for w in wins if w.get("front")), wins[0])
        out, secs, st = arm(link, front["psn"], front["addr"])
        print("\narm A  %-40r %s%s" % (
            front.get("title"), out,
            "" if secs is None else "  %.0f ms" % (secs * 1000)))
        time.sleep(args.settle)
        occ_a = occupancy(status(link))
        print("  after %.0fs settled: %s" % (args.settle, occ_a))
        readings["rows"].append({"phase": "armA", "window": front.get("title"),
                                 "outcome": out, "armMs": None if secs is None
                                 else round(secs * 1000),
                                 "occupancy": occ_a})

        # Reading 2: retarget to another window of the SAME process, if the
        # scene offers one; otherwise say so rather than inventing a row.
        peer = next((w for w in by_psn.get(front["psn"], [])
                     if w["addr"] != front["addr"]), None)
        if peer is None:
            print("\nNO SECOND WINDOW in the armed process — reading 2 and 3 "
                  "not taken. A cost this instrument could not measure is "
                  "reported as not measured, never as zero.")
            readings["rows"].append({"phase": "armB", "outcome": "no-peer"})
        else:
            out, secs, st = arm(link, peer["psn"], peer["addr"])
            print("\narm B  %-40r %s%s   (same process, already armed)" % (
                peer.get("title"), out,
                "" if secs is None else "  %.0f ms" % (secs * 1000)))
            time.sleep(args.settle)
            occ_b = occupancy(status(link))
            print("  after %.0fs settled: %s" % (args.settle, occ_b))
            print("  window A's rows after the retarget: hookedPorts went "
                  "%s -> %s" % (occ_a["hookedPorts"], occ_b["hookedPorts"]))
            readings["rows"].append({"phase": "armB",
                                     "window": peer.get("title"),
                                     "outcome": out,
                                     "armMs": None if secs is None
                                     else round(secs * 1000),
                                     "occupancy": occ_b})

        # Reading 4: the price of option (b), rotation, over a real app.
        if peer is not None and args.rounds > 0:
            readings["rotation"] = rotate(
                link, [front, peer], args.rounds, args.dwell)
            # A CONTROL for the same window-seconds with NO rotation, because
            # a ring-bytes number with nothing to compare it to says nothing:
            # a busy Finder writes ops whether or not anybody re-arms.
            base = occupancy(status(link))
            time.sleep(args.rounds * 2 * (args.dwell + 0.4))
            after = occupancy(status(link))
            readings["control"] = {
                "seconds": round(args.rounds * 2 * (args.dwell + 0.4), 1),
                "writeCursor": after["writeCursor"] - base["writeCursor"],
                "redrawRequests": after["redrawRequests"]
                    - base["redrawRequests"],
            }
            print("\ncontrol, same duration, ONE standing arm: %s"
                  % readings["control"])

        link.command("qdtrace", {"op": "stop"})
        if args.json:
            with open(args.json, "w") as fh:
                json.dump(readings, fh, indent=2)
            print("\nwrote %s" % args.json)
    finally:
        link.close()


if __name__ == "__main__":
    main()
