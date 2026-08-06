#!/usr/bin/env python3
"""How long does the content plane take to ARM, and what decides it.

The host's status line says `content: requested X's trace; waiting for its
event loop to arm` and nobody has ever timed that wait. The arm completes
only when the TARGET process next runs the extension's jGNE pass and agrees
it is the one named (ext/src/now_content.c :: now_content_gne), so the
quantity is really "how soon does that process pump its event loop".

WHAT THIS INSTRUMENT CAN AND CANNOT SEE. It is a host: it writes the arm
request over the wire and then polls `qdtrace status` over the same wire.
Its resolution is therefore ONE WIRE ROUND TRIP, and that floor is measured
first and printed beside every result rather than assumed small. Anything
that arms inside one round trip is reported as "within the floor" and NOT
as a number, because the number would be the instrument's own.

Every poll also makes NOW pump its event loop and yield, which is part of
what lets the target get scheduled. So this measures the wait UNDER
POLLING — exactly the condition the product is in, since the host polls
too — and is not a claim about an unobserved machine.

THE NULL CONTROL IS NOT OPTIONAL (drive-loop rule 2e, measurement rule 6).
`null` arms an A5 no process has. Nothing may ever report it armed; if a
run says it did, every number here is void. It is safe by construction:
the verdict is taken in the target's own context and compares the running
A5 against the requested one, so a bogus A5 installs nothing anywhere.

    tools/local-arm-latency.py --port 5450 --build 9a1d885 \
        --conditions self front background modal null

Scratch instrument, `local-*` like its neighbours: it drives one emulator
clone from one desk and ships to nobody.
"""

import argparse
import os
import statistics
import sys
import time

sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "scripts",
                                "probes"))
import nowwire  # noqa: E402

TTL_TICKS = 3600           # 60 s: long enough for a sample, short enough to lapse
POLL_BUDGET = 45.0         # before an arm is declared not to have come
BOGUS_A5 = 0x00BADA50      # odd-looking and, crucially, never a real A5 here


def walk(link):
    doc, _ = link.scene()
    procs = doc.get("processes") or []
    wins = doc.get("windows") or []
    return doc, procs, wins


def warm(link):
    """Throw away one scene per connection.

    docs/open-issues.md, the writer-lease entry: the FIRST scene of a fresh
    connection claims the plane and reads `arm_active` before the resident's
    next jGNE pass can echo it, so it answers `now_no_plane` for every
    foreign process. Measuring targets off that walk would report a machine
    with no windows on it but NOW's own — which is exactly what this
    instrument did on its first run.
    """
    walk(link)


def pick_window(wins, psn=None, front=None, name_has=None):
    """The exact window address is the only thing `qdtrace start` accepts —
    it refuses an all-windows arm — so a target with no window in the scene
    cannot be armed at all, and that is itself a finding."""
    for w in wins:
        if not w.get("addr"):
            continue
        if psn is not None and w.get("psn") != psn:
            continue
        if front is not None and bool(w.get("front")) != front:
            continue
        if name_has and name_has.lower() not in (w.get("title") or "").lower():
            continue
        return w
    return None


def refused(link):
    """The plane's unguarded refusal counters.

    Measurement rule 6: a guarded function cannot report on itself. These
    are bumped in `now_content_gne` per verdict, so `wrongContext` climbing
    while an arm does not land is the difference between "no process is
    pumping" and "processes are pumping and none of them is the target".
    Those are opposite repairs.
    """
    st = link.command("qdtrace", {"op": "status"}).get("qdtrace") or {}
    return dict(st.get("refused") or {}), dict(st.get("lifecycle") or {})


def arm_once(link, psn, addr, a5=None, budget=POLL_BUDGET, mid_run=None):
    """Request one arm and time it to the first status that reports it live.

    Returns a dict. `outcome` is 'armed', 'timeout' or 'refused:<code>' —
    never a bare number, because an arm that did not happen and an arm that
    happened instantly must not both read as a small float.

    `mid_run` is (seconds, callable): run it that far into the wait. It is
    how the deferred condition changes ONE variable — which process is
    frontmost — without restarting the request, so the before and after are
    the same arm and not two.
    """
    args = {"op": "start", "window": "0x%08x" % int(addr),
            "mode": "record", "ttlTicks": TTL_TICKS}
    if a5 is not None:
        args["a5"] = "0x%08x" % a5
    else:
        hi, lo = psn.split(".")
        args["serialHi"], args["serialLo"] = int(hi), int(lo)

    before, _ = refused(link)
    mid = link.send_async("qdtrace", args)
    result = link.read_result(mid)
    t_reply = time.time()
    if not result.get("ok"):
        return {"outcome": "refused:%s" % (
            (result.get("error") or {}).get("code")), "s": None, "polls": 0}
    out = (result.get("output") or {}).get("qdtrace") or {}
    generation = out.get("generation")
    want_a5 = out.get("a5")            # the guest's own word for who it resolved

    polls = 0
    fired = mid_run is None
    t_fired = None
    while time.time() - t_reply < budget:
        st = link.command("qdtrace", {"op": "status"}).get("qdtrace") or {}
        polls += 1
        active = st.get("active") or {}
        # BOTH, never the generation alone. A generation is a small counter
        # that a previous arm can still be sitting on; the A5 says WHOSE
        # context agreed. The first version matched on generation only and
        # the null control armed once because of it.
        if (active.get("generation") == generation
                and active.get("a5") == want_a5):
            after = dict(st.get("refused") or {})
            return {"outcome": "armed", "s": time.time() - t_reply,
                    "polls": polls, "generation": generation, "a5": want_a5,
                    "sinceFront": None if t_fired is None
                                  else time.time() - t_fired,
                    "wrongContext": (after.get("wrongContext", 0)
                                     - before.get("wrongContext", 0))}
        if active.get("generation") == generation:
            return {"outcome": "IMPOSSIBLE:generation-matched-wrong-a5",
                    "s": None, "polls": polls, "active": active,
                    "wanted": want_a5}
        if not fired and time.time() - t_reply >= mid_run[0]:
            mid_run[1]()
            t_fired = time.time()
            fired = True
    after, _ = refused(link)
    return {"outcome": "timeout", "s": None, "polls": polls,
            "generation": generation,
            "wrongContext": after.get("wrongContext", 0)
                            - before.get("wrongContext", 0),
            "expired": after.get("expired", 0) - before.get("expired", 0)}


def report(label, samples, floor):
    """A distribution, never one sample. A cooperatively scheduled machine
    has a tail and the tail is the part a person feels, so the max is
    printed beside the median rather than folded into a mean."""
    armed = [s for s in samples if s["outcome"] == "armed"]
    other = [s for s in samples if s["outcome"] != "armed"]
    print(f"\n=== {label}  (n={len(samples)}) ===")
    for code in sorted({s["outcome"] for s in other}):
        hits = [s for s in other if s["outcome"] == code]
        wc = [s.get("wrongContext") for s in hits if s.get("wrongContext")]
        print(f"  {len(hits)}x {code}"
              + (f"   other processes pumped and declined it "
                 f"{min(wc)}-{max(wc)} times meanwhile" if wc else ""))
    if not armed:
        print("  NOTHING ARMED. That is a result, not a missing measurement.")
        return
    ms = sorted(round(s["s"] * 1000) for s in armed)
    polls = [s["polls"] for s in armed]
    first = sum(1 for s in armed if s["polls"] <= 1)
    print(f"  ms: {ms}")
    print(f"  median={statistics.median(ms)}  min={ms[0]}  max={ms[-1]}  "
          f"polls median={statistics.median(polls)}")
    since = [round(s["sinceFront"] * 1000) for s in armed
             if s.get("sinceFront") is not None]
    if since:
        print(f"  ms AFTER the front change: {sorted(since)}  "
              f"median={statistics.median(since)}")
    print(f"  armed on the FIRST status poll: {first}/{len(armed)} — those "
          f"are bounded by the {floor:.0f}ms round-trip floor, not measured "
          f"by it")


# --- the conditions ----------------------------------------------------
#
# Each returns (psn, window addr, a5-or-None) for one sample, having put the
# machine into the state its name claims. A condition that cannot establish
# its own premise returns None rather than measuring something else — the
# first rule in docs/mirror-measurement-method.md.

def find(link, name, tries=3):
    """Walk until the named process appears WITH a window, or give up.

    Not a retry for luck: the writer-lease entry in docs/open-issues.md
    records the first walk after a quiet gap answering `now_no_plane` for
    every foreign process, and this instrument's first run skipped half its
    background samples to exactly that. A walk that cannot see the target
    is the instrument blinking, not the machine losing a window.
    """
    for _ in range(tries):
        _, procs, wins = walk(link)
        p = next((x for x in procs if x.get("name") == name), None)
        if p:
            w = pick_window(wins, psn=p.get("psn"))
            if w:
                return p.get("psn"), w["addr"], None
    return None


def cond_self(link):
    """NOW's own window while NOW is front. The floor case: this process is
    the one answering the wire, so it pumps between every poll."""
    link.command("front", {"target": "New Old World"})
    return find(link, "New Old World")


def cond_front(link):
    """The Finder, frontmost. What the product actually does — the host arms
    whichever process owns the front window."""
    link.command("front", {"target": "Finder"})
    return find(link, "Finder")


def cond_background(link):
    """The Finder with NOW in front of it. A background application still
    gets time from the Process Manager, but only when someone yields."""
    link.command("front", {"target": "New Old World"})
    return find(link, "Finder")


def cond_null(link):
    """An A5 no process has. Must never arm."""
    _, _, wins = walk(link)
    w = pick_window(wins)
    return (None, w["addr"], BOGUS_A5) if w else None


CONDITIONS = {
    "self": cond_self,
    "front": cond_front,
    "background": cond_background,
    "null": cond_null,
}


def run_deferred(link, samples, budget, defer_at):
    """The one-variable experiment the differential needs.

    Arm the Finder with NOW in front, wait, then bring the Finder forward
    WITHOUT re-requesting. Same arm, same generation, one variable moved.
    If a pending arm completes on the front change, the answer is that the
    background Finder was not pumping — not that the request was wrong.
    """
    out = []
    for i in range(samples):
        try:
            link.command("qdtrace", {"op": "stop"})
        except nowwire.GuestError:
            pass
        link.command("front", {"target": "New Old World"})
        setup = find(link, "Finder")
        if setup is None:
            print(f"  [deferred {i}] premise not established — SKIPPED")
            continue
        psn, addr, _ = setup
        r = arm_once(link, psn, addr, budget=budget,
                     mid_run=(defer_at,
                              lambda: link.send_async("front",
                                                      {"target": "Finder"})))
        out.append(r)
        print(f"  [deferred {i}] {r['outcome']} "
              f"total={None if r['s'] is None else round(r['s']*1000)}ms "
              f"afterFront={None if r.get('sinceFront') is None else round(r['sinceFront']*1000)}ms "
              f"polls={r['polls']} wrongContext+={r.get('wrongContext')}")
    return out


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, required=True)
    ap.add_argument("--build", default=None,
                    help="required prefix of the guest's build stamp")
    ap.add_argument("--wait", type=float, default=300.0)
    ap.add_argument("--samples", type=int, default=10)
    ap.add_argument("--conditions", nargs="*", default=["self", "front",
                                                        "background", "null"])
    ap.add_argument("--budget", type=float, default=POLL_BUDGET)
    ap.add_argument("--defer-at", type=float, default=10.0,
                    help="deferred: seconds to wait before fronting the target")
    ap.add_argument("--survey", action="store_true",
                    help="print the machine as found and stop")
    args = ap.parse_args()

    link = nowwire.GuestLink.await_guest(args.port, timeout=args.wait)
    build = link.hello.get("build", "")
    print(f"guest build: {build}  name={link.hello.get('name')}")
    if args.build and not build.startswith(args.build):
        sys.exit(f"WRONG GUEST: build {build!r} is not the build under test "
                 f"({args.build!r}) — every VM on this Mac dials 10.0.2.2")

    # The instrument's own floor, first and always. A result smaller than
    # this is a statement about this script and not about the Macintosh.
    rtt = []
    for _ in range(15):
        t = time.time()
        link.command("qdtrace", {"op": "status"})
        rtt.append((time.time() - t) * 1000)
    floor = statistics.median(rtt)
    print(f"\nwire floor: one `qdtrace status` round trip, median "
          f"{floor:.0f}ms  min {min(rtt):.0f}  max {max(rtt):.0f}")

    warm(link)
    doc, procs, wins = walk(link)
    print(f"processes: {[(p.get('name'), p.get('psn'), p.get('front')) for p in procs]}")
    print("coverage errors: %s" % ((doc.get("meta") or {}).get("errors") or []))
    for w in wins:
        print(f"  window addr={w.get('addr')} psn={w.get('psn')} "
              f"front={w.get('front')} title={w.get('title')!r}")
    if args.survey:
        link.close()
        return 0

    for name in args.conditions:
        if name == "deferred":
            report(name, run_deferred(link, args.samples, args.budget,
                                      args.defer_at), floor)
            continue
        fn = CONDITIONS.get(name)
        if fn is None:
            print(f"\n=== {name} === no such condition")
            continue
        samples = []
        for i in range(args.samples):
            try:
                link.command("qdtrace", {"op": "stop"})
            except nowwire.GuestError:
                pass
            setup = fn(link)
            if setup is None:
                print(f"  [{name} {i}] premise not established — SKIPPED "
                      "rather than measured against a different machine")
                continue
            psn, addr, a5 = setup
            r = arm_once(link, psn, addr, a5, budget=args.budget)
            samples.append(r)
            print(f"  [{name} {i}] {r['outcome']} "
                  f"{'' if r['s'] is None else round(r['s']*1000)}"
                  f"  polls={r['polls']} wrongContext+={r.get('wrongContext')}")
        report(name, samples, floor)

    link.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
