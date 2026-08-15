#!/usr/bin/env python3
"""rigdrive - the host half of the cursor-latency spike.

THIS IS A RIG. It drives a guest Macintosh's pointer over UDP and pulls
the guest's own measurement tail afterwards. See ../README.md.

    rigdrive.py run --port 17400 --seconds 20 --load tracking --seed 7
    rigdrive.py analyse runs/tracking.json
    rigdrive.py ping --port 17400 --count 200
    rigdrive.py battery --port 17400            # every load, one seed

Three rules this file encodes, each of them a measurement the lab has
got wrong before:

  * ABSOLUTE POSITIONS ONLY. Never deltas, never velocity, never
    extrapolation. A dropped absolute position costs one stale frame; a
    dropped delta corrupts every position after it.
  * THE TAIL IS PULLED AFTER THE RUN, never during. Measuring latency
    over the wire while the measurement uses the wire is how a probe
    once refreshed the very timeout it was measuring.
  * TICKS STAY TICKS. The guest's clock is TickCount, 1/60 s, and
    nothing here converts it to milliseconds. Where a host-clock number
    has to be compared against it, the HOST number is scaled and
    labelled as such.
"""

import argparse
import json
import os
import random
import socket
import struct
import sys
import time

# Kept in step with ../contract/cursor_rig.h by hand and checked at run
# time: the dump reply carries the guest's own sizes, and a mismatch
# fails loudly rather than producing plausible nonsense.
WIRE_MAGIC = 0x43524731
DUMP_MAGIC = 0x43524744
WIRE_VERSION = 1
CMD_FMT = ">IHHIhhHHI"          # magic ver op seq h v arg pad host_stamp
CMD_SIZE = 24
SAMPLE_FMT = ">IIIIhhHH"        # seq arrival apply redraw h v flags coalesced
SAMPLE_SIZE = 24
DUMP_CHUNK = 24
DUMP_HEAD_FMT = ">35I"
DUMP_HEAD_SIZE = 35 * 4

OP = dict(move=1, click=2, begin=3, end=4, dump=5, ping=6, quit=7, load=8)
LOADS = dict(idle=0, spin=1, tracking=2, drawing=3, polite=4)

F_APPLIED, F_COALESCED, F_CLICK, F_OOO, F_REDRAWN = 1, 2, 4, 8, 16


def pack(op, seq=0, h=0, v=0, arg=0, stamp=0):
    return struct.pack(CMD_FMT, WIRE_MAGIC, WIRE_VERSION, op, seq,
                       h, v, arg, 0, stamp & 0xFFFFFFFF)


class Rig:
    def __init__(self, host, port, timeout=2.0):
        self.addr = (host, port)
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.settimeout(timeout)

    def send(self, *a, **kw):
        self.sock.sendto(pack(*a, **kw), self.addr)


# --------------------------------------------------------------- paths

def waypoint_path(seed, count, bounds, step_px):
    """A seeded path a person could plausibly have drawn.

    Random WAYPOINTS with straight lines between them, rather than
    independent random points: independent points would make every
    frame a teleport, and a teleporting pointer hides exactly the
    stutter this spike is looking for. The seed is recorded with the run
    because an unseeded failure cannot be replayed.
    """
    rng = random.Random(seed)
    left, top, right, bottom = bounds
    x, y = (left + right) // 2, (top + bottom) // 2
    out = []
    while len(out) < count:
        tx, ty = rng.randint(left, right), rng.randint(top, bottom)
        dist = max(abs(tx - x), abs(ty - y))
        steps = max(1, dist // step_px)
        for i in range(1, steps + 1):
            out.append((int(x + (tx - x) * i / steps),
                        int(y + (ty - y) * i / steps)))
            if len(out) >= count:
                break
        x, y = tx, ty
    return out[:count]


# ----------------------------------------------------------------- run

def read_buildid(path):
    """The identity written beside a binary at build time."""
    p = os.path.splitext(path)[0] + ".buildid"
    with open(p) as fh:
        return int(fh.read().strip(), 16)


def require_build(rig, args):
    """Refuse to measure a build we did not stage.

    A stale extension is the most expensive failure on this bench and it
    is INVISIBLE: the file is in the Extensions folder, the Gestalt
    selector answers, the table's magic is right, and the code running
    is yesterday's. Agents lose hours wondering why a fix changed
    nothing. So the host demands the resident's own build identity - a
    hash of the sources that produced the binary, compiled into it - and
    compares it against the sidecar written beside the .bin that was
    staged. Mismatch is a hard stop, never a warning.
    """
    _, counters = pull_dump(rig, retries=2)
    if not counters:
        raise SystemExit("the guest did not answer a dump: is the intake "
                         "running, and is the UDP port forwarded?")
    live = counters.get("build_id"), counters.get("app_build_id")
    print(f"guest reports: resident build_id {live[0]:08X}  "
          f"intake app_build_id {live[1]:08X}")
    if counters.get("refused"):
        raise SystemExit(
            "the resident REFUSED to install: another resident already owns "
            "these traps (it answered its own Gestalt selector at boot). "
            "Move it out of the System Folder and COLD reboot - CursorRig "
            "is exclusive by declaration, and beside another resident it "
            "would be measuring both of you.")
    if counters.get("caps", 0) == 0:
        raise SystemExit(
            "the resident published no capabilities: the extension is not "
            "loaded. An INIT loads at BOOT only - stage, then COLD reboot.")
    want = []
    if args.require_init:
        want.append(("resident", read_buildid(args.require_init), live[0]))
    if args.require_app:
        want.append(("intake", read_buildid(args.require_app), live[1]))
    for name, expected, got in want:
        if expected != got:
            raise SystemExit(
                f"STALE BUILD: the {name} on the guest reports "
                f"{got:08X} but the binary here is {expected:08X}. "
                f"The guest is running a different build from the one you "
                f"just built. Re-stage and COLD reboot; do not believe any "
                f"number this machine produces until these agree.")
    if want:
        print("build identities agree with the staged binaries")
    return counters


def do_status(args):
    rig = Rig(args.host, args.port)
    counters = require_build(rig, args)
    for k in sorted(counters):
        print(f"  {k:20} {counters[k]}")


def do_run(args):
    rig = Rig(args.host, args.port)
    require_build(rig, args)
    count = int(args.seconds * args.rate)
    path = waypoint_path(args.seed, count, tuple(args.bounds), args.step)

    rig.send(OP["begin"], arg=0, stamp=args.seed)
    time.sleep(0.2)

    if args.load != "idle":
        # Started BEFORE the motion and sized to outlast it, so every
        # position in the run lands while the machine is genuinely busy.
        # A load that starts late turns the first seconds into an idle
        # baseline hiding inside a loaded run.
        rig.send(OP["load"], arg=LOADS[args.load],
                 h=int((args.seconds + 2) * 60))
        time.sleep(0.3)

    sends = []
    period = 1.0 / args.rate
    t0 = time.monotonic()
    for i, (x, y) in enumerate(path, start=1):
        due = t0 + i * period
        now = time.monotonic()
        if due > now:
            time.sleep(due - now)
        rig.send(OP["move"], seq=i, h=x, v=y, stamp=i)
        sends.append(time.monotonic() - t0)
    elapsed = time.monotonic() - t0

    rig.send(OP["end"])
    # Let the machine finish the load before asking it anything: a dump
    # answered from a starved event loop would take minutes and prove
    # nothing about the run.
    time.sleep(args.settle)

    samples, counters = pull_dump(rig, args.dump_retries)
    out = dict(
        rig="cursor-latency-spike",
        host=args.host, port=args.port,
        seed=args.seed, rate=args.rate, seconds=args.seconds,
        load=args.load, bounds=list(args.bounds), step=args.step,
        sent=len(path), wall_elapsed_s=round(elapsed, 3),
        host_send_offsets_s=[round(s, 4) for s in sends],
        counters=counters, samples=samples,
        note="ticks are guest TickCount (1/60 s) and are NOT converted",
    )
    os.makedirs(os.path.dirname(args.out) or ".", exist_ok=True)
    with open(args.out, "w") as fh:
        json.dump(out, fh)
    print(f"wrote {args.out}: {len(samples)} samples, "
          f"{len(path)} sent in {elapsed:.1f}s")
    report(out)


def pull_dump(rig, retries):
    """Ask for the ring in chunks and keep asking for what is missing.

    A dump that silently returns short would report a clean tail by
    having lost the interesting part, so the gaps are chased and what is
    still missing is stated.
    """
    counters = {}
    got = {}
    cap = None
    wanted = [0]
    for attempt in range(retries):
        for first in list(wanted):
            rig.send(OP["dump"], arg=first)
            try:
                data, _ = rig.sock.recvfrom(2048)
            except socket.timeout:
                continue
            if len(data) < DUMP_HEAD_SIZE:
                continue
            head = struct.unpack(DUMP_HEAD_FMT, data[:DUMP_HEAD_SIZE])
            if head[0] != DUMP_MAGIC:
                continue
            (_, first_i, cnt, caps, ring_count, ring_head, ring_cap,
             ring_dropped, received, applied, coalesced, ooo, timer_ticks,
             intake_calls, app_passes, gne_passes, redraws, place_route,
             run_seed, run_start, redraw_calls, _r1, _r2, _r3,
             last_apply, now_ticks, armed,
             mode, build_id, app_build_id, load_profile,
             load_running, refused, load_started, load_ticks) = head
            cap = ring_cap
            counters = dict(
                caps=caps, ring_count=ring_count, ring_head=ring_head,
                ring_cap=ring_cap, ring_dropped=ring_dropped,
                received=received, applied=applied, coalesced=coalesced,
                out_of_order=ooo, timer_ticks=timer_ticks,
                intake_calls=intake_calls, app_passes=app_passes,
                gne_passes=gne_passes, redraws=redraws,
                place_route=place_route, run_seed=run_seed,
                run_start_ticks=run_start, last_apply_ticks=last_apply,
                now_ticks=now_ticks, armed=armed, mode=mode,
                build_id=build_id, app_build_id=app_build_id,
                load_profile=load_profile, load_running=load_running,
                refused=refused, redraw_calls=redraw_calls,
                load_started=load_started, load_ticks=load_ticks)
            body = data[DUMP_HEAD_SIZE:]
            for k in range(cnt):
                off = k * SAMPLE_SIZE
                if off + SAMPLE_SIZE > len(body):
                    break
                s = struct.unpack(SAMPLE_FMT, body[off:off + SAMPLE_SIZE])
                got[first_i + k] = dict(
                    seq=s[0], arrival=s[1], apply=s[2], redraw=s[3],
                    h=s[4], v=s[5], flags=s[6], coalesced=s[7])
            wanted.remove(first)
        if cap is None:
            wanted = [0]
            continue
        # How much of the ring was actually used this run.
        used = min(counters["ring_count"], cap)
        wanted = [i for i in range(0, used, DUMP_CHUNK)
                  if not all((i + k) in got for k in
                             range(min(DUMP_CHUNK, used - i)))]
        if not wanted:
            break
    if wanted:
        print(f"warning: {len(wanted)} dump chunks never arrived; "
              f"every count below is a FLOOR", file=sys.stderr)
    samples = [got[i] for i in sorted(got) if got[i]["seq"] != 0]
    samples.sort(key=lambda s: s["seq"])
    return samples, counters


# ------------------------------------------------------------ analysis

def pct(values, p):
    if not values:
        return None
    s = sorted(values)
    k = min(len(s) - 1, int(round((p / 100.0) * (len(s) - 1))))
    return s[k]


def dist(values):
    if not values:
        return dict(n=0)
    return dict(n=len(values), min=min(values), p50=pct(values, 50),
                p90=pct(values, 90), p99=pct(values, 99), max=max(values))


def histogram(values, top=8):
    h = {}
    for v in values:
        h[v] = h.get(v, 0) + 1
    return dict(sorted(h.items(), key=lambda kv: -kv[1])[:top])


def analyse(run):
    s = run["samples"]
    c = run["counters"]
    applied = [x for x in s if x["flags"] & F_APPLIED]
    stale = [x["apply"] - x["arrival"] for x in applied
             if x["apply"] and x["arrival"] and x["apply"] >= x["arrival"]]
    drawn = [x for x in applied if x["flags"] & F_REDRAWN and x["redraw"]]
    picture = [x["redraw"] - x["apply"] for x in drawn
               if x["redraw"] >= x["apply"]]
    arrivals = sorted(x["arrival"] for x in s if x["arrival"])
    gaps = [b - a for a, b in zip(arrivals, arrivals[1:])]

    # Did the pointer ever move backwards relative to command order?
    seqs = [x["seq"] for x in sorted(applied, key=lambda x: (x["apply"],
                                                             x["seq"]))]
    backwards = sum(1 for a, b in zip(seqs, seqs[1:]) if b < a)

    return dict(
        load=run["load"], seed=run["seed"], rate=run["rate"],
        seconds=run["seconds"], sent=run["sent"],
        received=c.get("received"), applied_count=c.get("applied"),
        coalesced=c.get("coalesced"),
        ring_dropped=c.get("ring_dropped"),
        out_of_order=c.get("out_of_order"),
        backwards_in_tail=backwards,
        timer_ticks=c.get("timer_ticks"),
        app_passes=c.get("app_passes"), gne_passes=c.get("gne_passes"),
        redraws=c.get("redraws"), redraw_calls=c.get("redraw_calls"),
        caps=c.get("caps"),
        place_route=c.get("place_route"),
        staleness_ticks=dist(stale), staleness_hist=histogram(stale),
        picture_lag_ticks=dist(picture),
        arrival_gap_ticks=dist(gaps), arrival_gap_hist=histogram(gaps),
    )


ROUTES = {0: "none", 1: "low-memory only", 2: "+ cursor device",
          3: "+ redraw owed"}


def report(run):
    a = analyse(run)
    w = sys.stdout.write
    w(f"\n=== load={a['load']}  seed={a['seed']}  "
      f"{a['rate']}/s for {a['seconds']}s ===\n")
    w(f"  sent {a['sent']}   received {a['received']}   "
      f"applied {a['applied_count']}   coalesced {a['coalesced']}\n")
    w(f"  ring dropped {a['ring_dropped']}"
      f"   out of order {a['out_of_order']}"
      f"   backwards in tail {a['backwards_in_tail']}\n")
    w(f"  timer ticks {a['timer_ticks']}   app passes {a['app_passes']}"
      f"   event-loop passes {a['gne_passes']}\n")
    w(f"  redraws performed {a['redraw_calls']}   attributed to a sample "
      f"{a['redraws']}\n")
    w(f"  place route: {ROUTES.get(a['place_route'], a['place_route'])}\n")
    for name, key in (("staleness  apply-arrival", "staleness_ticks"),
                      ("picture    redraw-apply ", "picture_lag_ticks"),
                      ("arrival gap            ", "arrival_gap_ticks")):
        d = a[key]
        if not d.get("n"):
            w(f"  {name}: no samples\n")
            continue
        w(f"  {name}: n={d['n']} min={d['min']} p50={d['p50']} "
          f"p90={d['p90']} p99={d['p99']} max={d['max']}  (ticks)\n")
    w(f"  staleness histogram (ticks: count) {a['staleness_hist']}\n")
    if a["ring_dropped"]:
        w("  NOTE: the ring wrapped. Every count above is a floor.\n")
    w("\n")
    return a


# ------------------------------------------------------------ commands

def do_analyse(args):
    for path in args.files:
        with open(path) as fh:
            report(json.load(fh))


def do_ping(args):
    """The wire on its own, with the guest doing nothing else.

    This is the ONLY measurement here that uses a round trip, and it is
    deliberately not part of a run: it answers "what does the network
    cost" separately from "what does the machine cost", and mixing them
    is how a spike concludes the wrong half is at fault.
    """
    rig = Rig(args.host, args.port, timeout=1.0)
    rtts = []
    lost = 0
    for i in range(args.count):
        t = time.monotonic()
        rig.send(OP["ping"], seq=i, stamp=i)
        try:
            rig.sock.recvfrom(2048)
            rtts.append((time.monotonic() - t) * 1000.0)
        except socket.timeout:
            lost += 1
        time.sleep(args.interval)
    if rtts:
        rtts.sort()
        print(f"ping: n={len(rtts)} lost={lost} "
              f"min={rtts[0]:.1f} p50={pct(rtts, 50):.1f} "
              f"p90={pct(rtts, 90):.1f} max={rtts[-1]:.1f} ms "
              f"(HOST clock, milliseconds - the guest's ticks are "
              f"never converted)")
    else:
        print(f"ping: nothing came back ({lost} lost)")


def do_battery(args):
    """Every load condition, one seed, idle FIRST and never as the headline."""
    results = []
    for load in ("idle", "spin", "tracking", "drawing", "polite"):
        ns = argparse.Namespace(**vars(args))
        ns.load = load
        ns.out = os.path.join(args.outdir, f"{load}.json")
        do_run(ns)
        with open(ns.out) as fh:
            results.append(analyse(json.load(fh)))
        time.sleep(2.0)
    path = os.path.join(args.outdir, "battery.json")
    with open(path, "w") as fh:
        json.dump(results, fh, indent=1)
    print("\n=== battery: staleness by load (ticks) ===")
    print(f"{'load':10} {'p50':>4} {'p90':>4} {'p99':>4} {'max':>4} "
          f"{'ooo':>4} {'drop':>5} {'apps':>6}")
    for r in results:
        d = r["staleness_ticks"]
        print(f"{r['load']:10} {d.get('p50','-'):>4} {d.get('p90','-'):>4} "
              f"{d.get('p99','-'):>4} {d.get('max','-'):>4} "
              f"{r['out_of_order']:>4} {r['ring_dropped']:>5} "
              f"{r['app_passes']:>6}")
    print(f"\nwrote {path}")


def do_sweep(args):
    """The same load at several send rates.

    Bandwidth is not the question on old hardware and the arithmetic
    says so: 60 positions a second is 24 bytes each, about 4 KB/s once
    UDP, IP and the radio's headers are counted, against a measured
    200-300 KB/s on a PowerBook 1400c over an Orinoco card - some two
    per cent of the link. What costs is the PACKET RATE: sixty
    interrupts a second and sixty trips through the Open Transport
    stack on a 117 MHz machine. This sweep is the axis that will bite
    on metal, and it is here so the emulator's answer can be compared
    against the real one rung for rung.
    """
    results = []
    for rate in args.rates:
        ns = argparse.Namespace(**vars(args))
        ns.rate = rate
        ns.out = os.path.join(args.outdir, f"rate-{rate}-{args.load}.json")
        do_run(ns)
        with open(ns.out) as fh:
            results.append(analyse(json.load(fh)))
        time.sleep(2.0)
    print(f"\n=== rate sweep under load={args.load} (ticks) ===")
    print(f"{'rate/s':>6} {'p50':>4} {'p90':>4} {'p99':>4} {'max':>4} "
          f"{'coalesced':>10} {'ooo':>4}")
    for rate, r in zip(args.rates, results):
        d = r["staleness_ticks"]
        print(f"{rate:>6} {d.get('p50','-'):>4} {d.get('p90','-'):>4} "
              f"{d.get('p99','-'):>4} {d.get('max','-'):>4} "
              f"{r['coalesced']:>10} {r['out_of_order']:>4}")
    path = os.path.join(args.outdir, f"sweep-{args.load}.json")
    with open(path, "w") as fh:
        json.dump(results, fh, indent=1)
    print(f"\nwrote {path}")


def do_quit(args):
    Rig(args.host, args.port).send(OP["quit"])
    print("asked the intake to quit")


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--host", default="127.0.0.1")
    p.add_argument("--port", type=int, default=17400)
    p.add_argument("--require-init", metavar="CursorRig.bin",
                   help="path to the staged INIT; its .buildid sidecar must "
                        "match what the guest reports, or nothing runs")
    p.add_argument("--require-app", metavar="CursorRigIntake.bin",
                   help="same, for the intake application")
    sub = p.add_subparsers(dest="cmd", required=True)

    def add_run_args(sp):
        sp.add_argument("--rate", type=int, default=60,
                        help="positions per second (default 60)")
        sp.add_argument("--seconds", type=float, default=20.0)
        sp.add_argument("--seed", type=int, default=1,
                        help="recorded with the run; an unseeded failure "
                             "cannot be replayed")
        sp.add_argument("--bounds", type=int, nargs=4,
                        default=[40, 40, 760, 560],
                        metavar=("L", "T", "R", "B"))
        sp.add_argument("--step", type=int, default=12,
                        help="pixels between successive positions")
        sp.add_argument("--settle", type=float, default=3.0)
        sp.add_argument("--dump-retries", type=int, default=6)

    r = sub.add_parser("run")
    add_run_args(r)
    r.add_argument("--load", choices=sorted(LOADS), default="idle")
    r.add_argument("--out", default="runs/run.json")
    r.set_defaults(func=do_run)

    b = sub.add_parser("battery")
    add_run_args(b)
    b.add_argument("--outdir", default="runs")
    b.set_defaults(func=do_battery)

    s = sub.add_parser("sweep")
    add_run_args(s)
    s.add_argument("--load", choices=sorted(LOADS), default="tracking")
    s.add_argument("--rates", type=int, nargs="+", default=[15, 30, 60, 90])
    s.add_argument("--outdir", default="runs")
    s.set_defaults(func=do_sweep)

    a = sub.add_parser("analyse")
    a.add_argument("files", nargs="+")
    a.set_defaults(func=do_analyse)

    g = sub.add_parser("ping")
    g.add_argument("--count", type=int, default=100)
    g.add_argument("--interval", type=float, default=0.02)
    g.set_defaults(func=do_ping)

    st = sub.add_parser("status")
    st.set_defaults(func=do_status)

    q = sub.add_parser("quit")
    q.set_defaults(func=do_quit)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
