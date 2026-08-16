#!/usr/bin/env python3
"""Hold a guest menu open past the lease and ask whether arrival_ticks froze.

THE SHAPE THIS REPRODUCES, and why it needs a live guest at all. Continuity's
UDP endpoint is drained from an Open Transport notifier, and until 2026-08-16
that drain capped at 8 datagrams and handed the rest to a poll running in NOW's
own cooperative context. Inside a FOREIGN application's held-button nested loop
- OS 9 menu tracking - that context does not run. T_DATA is edge-triggered, so
one capped drain silenced the endpoint for the length of the hold: the shared
cell's arrival_ticks froze while the host was alive and sending keepalives, the
resident's ~1.5s lease expired, and the held button was released into the open
menu and launched an application the person never chose.

No unit test can see that. The freeze is a property of what still executes when
the application does not, so the instrument has to press a real menu title on a
real guest and keep sending.

WHAT THIS ASSERTS BEFORE IT BELIEVES ANYTHING (AGENTS.md: an instrument that
reads a live machine must assert the plane armed, and a gate must check WHICH
build answered):

  - the guest carries THIS fix, proven by an artifact only this build can
    produce - the per-epoch `continuity arrival ... age=` line. A build without
    it cannot be tested for the thing it does not have;
  - the Continuity capability is present in the resident, so a quarantine build
    cannot masquerade as a trial;
  - datagrams were ACCEPTED before the hold began. "No lease expiry" is
    worthless if nothing was ever arriving: that is absence and success in the
    same words.

The verdict is read from the guest's own account of the epoch, not from this
process's opinion of it.
"""

import argparse
import json
import os
import re
import select
import socket
import sys
import time
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "tools"))
import nowwire  # noqa: E402
from continuity_contract import load as load_continuity_contract  # noqa: E402

CONTINUITY = load_continuity_contract(Path(ROOT))
ACK = CONTINUITY.ack_struct

# The Finder's menu bar is 20pt tall and "File" sits a few points in. A press
# here opens a menu and enters MenuSelect, which is the nested loop the whole
# defect lives inside.
MENU_TITLE = (44, 8)
# Far from any pulled-down menu. Releasing here selects nothing, which is the
# difference between a probe and the incident it reproduces.
SAFE_RELEASE = (600, 400)
# The old notifier cap. A drain that never exceeded it is a drain that was
# never behind, which means task time was never starved and the hold proved
# nothing - see FOREIGN_APP below for the way that happens silently.
SOFT_CAP = 8

# Deliberately two patterns over two log lines: the guest truncates a log
# line near 110 characters, and a regex spanning that edge would silently stop
# matching the moment a counter grew a digit.
ARRIVAL_LINE = re.compile(
    r"continuity arrival epoch=(?P<epoch>\d+) age=(?P<age>\d+) "
    r"lease=(?P<lease>\d+) ticks")
DRAIN_LINE = re.compile(
    r"continuity drain epoch=(?P<epoch>\d+) burst-max=(?P<burst>\d+) "
    r"handoff=(?P<handoff>\d+) starved=(?P<starved>\d+) owed=(?P<owed>\d+) "
    r"delivered=(?P<delivered>\d+)/(?P<delivered_endpoint>\d+)")


def state(nonce_hi, nonce_lo, epoch, seq, h, v, generation, flags, stamp):
    return CONTINUITY.encode_state(
        nonce_hi, nonce_lo, epoch, seq, h, v, generation, 60, stamp, flags)


def drain_acks(udp, nonce_hi, nonce_lo, epoch, seen):
    """Take every queued ACK without ever making delivery wait for one.

    Delivery must not be coupled to acknowledgement: a rig that waited would
    stop its own keepalives and test the deadman lease it is trying to keep
    alive, which is how a previous harness measured the wrong thing.
    """
    while True:
        ready, _, _ = select.select([udp], [], [], 0)
        if not ready:
            return
        try:
            ack = CONTINUITY.decode_ack(udp.recv(ACK.size))
        except ValueError:
            continue
        if (ack["nonceHi"], ack["nonceLo"], ack["epoch"]) != (
                nonce_hi, nonce_lo, epoch):
            continue          # a late ACK from a finished lease
        seen.append(ack)


def arm(wire, nonce_hi, nonce_lo, epoch, lease_ticks):
    report = wire.ask("continuity.arm", version=CONTINUITY.version,
                      nonceHi=nonce_hi, nonceLo=nonce_lo, epoch=epoch,
                      requestedHz=60, leaseTicks=lease_ticks)
    if report.get("state") not in ("armed", "active"):
        raise RuntimeError(f"arm refused: {report}")
    return report


def disarm(wire, epoch):
    return wire.ask("continuity.disarm", version=CONTINUITY.version,
                    epoch=epoch, reason="disabled")


def arrival_report(wire, epoch, pages=3):
    """The guest's own account, read out of its own log.

    `tail` pages backwards, so walk back a few pages: a busy epoch can push
    the line off the newest one, and reporting "no line" for a line that
    merely scrolled would be the same class of mistake as reporting absence
    and defect in the same words.
    """
    seen = []
    before = None
    for _ in range(pages):
        line = f"tail 40 mirror" if before is None \
            else f"tail 40 mirror before {before}"
        ok, text = wire.exec_line(line)
        if not ok:
            break
        seen.append(text)
        for found in ARRIVAL_LINE.finditer(text):
            if int(found.group("epoch")) != epoch:
                continue
            fields = {k: int(v) for k, v in found.groupdict().items()}
            texts = [found.group(0)]
            for drain in DRAIN_LINE.finditer(text):
                if int(drain.group("epoch")) == epoch:
                    fields.update({k: int(v)
                                   for k, v in drain.groupdict().items()})
                    texts.append(drain.group(0))
            if "starved" not in fields:
                # The pair is written together; seeing one without the other
                # means the log rolled between them, and half an account is
                # not an account.
                continue
            return fields, " | ".join(texts)
        match = re.search(r"before (\d+)", text)
        if not match:
            break
        before = match.group(1)
    return None, "\n".join(seen)[-2000:]


def hold_menu(udp, nonce_hi, nonce_lo, epoch, hold_s, hz, acks, burst):
    """Press a menu title, keep sending through the hold, release safely.

    WHY THE STREAM IS BURSTY, and why that is the faithful stimulus rather
    than a cheat. The defect is not "a fast sender": it is a drain that ENDS
    OWING WORK while task time is unreachable. On this emulator NOW's OT
    notifier keeps up with a level 60 Hz stream one or two datagrams at a
    time, so no drain ever reaches its bound, no debt is ever handed over,
    and a five-second hold reads healthy from a build with the bug in it -
    measured, twice, before this argument was written down.

    A slower machine produces the pile-up from interrupt latency alone; the
    PowerBook did. Here it is produced deliberately, by sending a group
    back-to-back, which is also what a real host's coalesced position, button
    and keepalive traffic looks like arriving after a network hiccup. What
    the guest sees is identical either way: more datagrams queued than one
    drain was allowed to take.
    """
    seq = [0]
    generation = [0]

    def send(h, v, down, stamp):
        seq[0] += 1
        flags = CONTINUITY.flag_inside
        if down:
            flags |= CONTINUITY.flag_primary_down
        udp.send(state(nonce_hi, nonce_lo, epoch, seq[0], h, v,
                       generation[0], flags, stamp))
        drain_acks(udp, nonce_hi, nonce_lo, epoch, acks)

    # Settle on the title before pressing, so the press lands where intended.
    started = time.time()
    for _ in range(int(hz * 0.5)):
        send(MENU_TITLE[0], MENU_TITLE[1], False, seq[0])
        time.sleep(1.0 / hz)
    before_press = len(acks)

    generation[0] = 1
    press_at = time.time()
    next_burst = press_at + 0.5
    while time.time() - press_at < hold_s:
        # A point or two of jitter inside the title: a live host never sends a
        # perfectly static stream, and a coalescing resident may ignore one.
        wobble = int((time.time() - press_at) * 4) % 3
        if time.time() >= next_burst:
            for step in range(burst):
                send(MENU_TITLE[0] + (step % 3), MENU_TITLE[1], True, seq[0])
            next_burst = time.time() + 0.5
            continue
        send(MENU_TITLE[0] + wobble, MENU_TITLE[1], True, seq[0])
        time.sleep(1.0 / hz)
    held_for = time.time() - press_at

    # Leave the menu before letting go, then release, then keep the stream
    # alive long enough for task time to return and answer.
    for _ in range(int(hz * 0.3)):
        send(SAFE_RELEASE[0], SAFE_RELEASE[1], True, seq[0])
        time.sleep(1.0 / hz)
    generation[0] = 2
    for _ in range(int(hz * 1.0)):
        send(SAFE_RELEASE[0], SAFE_RELEASE[1], False, seq[0])
        time.sleep(1.0 / hz)
    return {"held_seconds": round(held_for, 3),
            "sent": seq[0],
            "acks_before_press": before_press,
            "elapsed": round(time.time() - started, 3)}


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", required=True, type=int,
                    help="this lane's wire port (tools/lane-ports)")
    ap.add_argument("--udp-host", default="127.0.0.1")
    ap.add_argument("--hold", type=float, default=5.0,
                    help="seconds to hold the menu; must exceed the lease")
    ap.add_argument("--hz", type=float, default=60.0)
    ap.add_argument("--burst", type=int, default=24,
                    help="datagrams sent back-to-back twice a second during "
                         "the hold; must exceed the old cap of 8 or no drain "
                         "ever ends owing work (see hold_menu)")
    ap.add_argument("--lease-ticks", type=int, default=90,
                    help="what the real host arms (90 ticks = 1.5s)")
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--front", default="Finder",
                    help="the FOREIGN application whose menu is held; NOW "
                         "itself is not one, and using it makes the run "
                         "vacuous")
    ap.add_argument("--expect-build",
                    help="prefix of the guest build hash this run is about. "
                         "A restage can fail and leave the PREVIOUS build "
                         "answering - it did here, and the old build passed "
                         "the control run because it was never replaced.")
    ap.add_argument("--expect", choices=("survives", "freezes"),
                    default="survives",
                    help="'freezes' inverts the verdict, for watching a "
                         "mutated build fail the way the incident did")
    args = ap.parse_args()
    os.makedirs(args.artifacts, exist_ok=True)

    result = {"expect": args.expect, "hold_requested_s": args.hold,
              "lease_ticks": args.lease_ticks}
    wire = nowwire.GuestWire(args.port, host="0.0.0.0",
                             name="continuity-starvation-probe")
    wire.accept(wait=240)
    result["build"] = str(wire.hello.get("build") or "")
    if args.expect_build and not result["build"].startswith(args.expect_build):
        raise SystemExit(
            f"wrong guest build: {result['build']!r} does not start with "
            f"{args.expect_build!r}")

    ext = ((wire.command("mirror").get("output") or {}).get("mirror")
           or {}).get("extension") or {}
    caps = int(ext.get("capabilities") or 0)
    result["extension_capabilities"] = caps
    if not caps & 0x200:
        raise SystemExit(
            f"Continuity capability is clear (caps={caps}); refusing a trial "
            "against a resident that cannot serve it")

    nonce_hi, nonce_lo = 0x5A11ED00, 0x0FA11BAC
    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setblocking(False)
    udp.connect((args.udp_host, args.port))

    # --- assert the build under test, by an artifact only it can produce ---
    #
    # Not "I deployed the right thing": the disarm line either appears or it
    # does not, and every number below is read out of that same line.
    acks = []
    arm(wire, nonce_hi, nonce_lo, 1, args.lease_ticks)
    for seq in range(1, 31):
        udp.send(state(nonce_hi, nonce_lo, 1, seq, 300, 240, 0,
                       CONTINUITY.flag_inside, seq))
        drain_acks(udp, nonce_hi, nonce_lo, 1, acks)
        time.sleep(1.0 / args.hz)
    disarm(wire, 1)
    time.sleep(0.5)
    warmup, warmup_text = arrival_report(wire, 1)
    result["build_under_test_line"] = warmup_text
    if warmup is None:
        raise SystemExit(
            "this guest does not report `continuity arrival ... age=` at "
            "disarm, so it is not the build under test; the starvation fix "
            "is what introduces that line")
    if not acks:
        raise SystemExit(
            "no acknowledgement arrived during warm-up: nothing was reaching "
            "the guest, so a later 'no lease expiry' would mean nothing")

    # --- A FOREIGN APPLICATION MUST BE IN FRONT, AND THIS IS NOT A DETAIL ---
    #
    # The first run of this probe held a menu for five seconds and reported a
    # healthy epoch from a build with the fix and, identically, from one
    # without it. NOW was frontmost: its own nested loops pump the wire by
    # design (pump.h), so the press opened NOW's menu and task time never
    # stopped. The rig reproduced nothing and said "survives" both times.
    #
    # So the front process is asserted, by name, out of the guest's own `ps`.
    ok, front_text = wire.exec_line(f"front {args.front}")
    result["front"] = front_text.strip()[:200]
    if not ok or "frontmost" not in front_text:
        raise SystemExit(
            f"could not bring {args.front} to the front: {front_text!r}; "
            "a hold against NOW's own menu tests the pump, not the notifier")
    time.sleep(1.0)
    ok, ps_text = wire.exec_line("ps")
    if not re.search(rf"{re.escape(args.front)}\s+\S+[^,]*, front", ps_text):
        raise SystemExit(
            f"{args.front} is not frontmost in the guest's own ps: {ps_text!r}")

    # --- the run itself ---
    epoch = 2
    acks = []
    exits = []
    arm(wire, nonce_hi, nonce_lo, epoch, args.lease_ticks)
    if args.burst <= SOFT_CAP:
        raise SystemExit(
            f"--burst {args.burst} cannot outrun the old cap of {SOFT_CAP}; "
            "no drain would end owing work and the hold would prove nothing")
    run = hold_menu(udp, nonce_hi, nonce_lo, epoch,
                    args.hold, args.hz, acks, args.burst)
    result.update(run)
    result["acks"] = len(acks)
    result["accepted_before_press"] = run["acks_before_press"]
    for ack in acks:
        if ack["exitReason"] != CONTINUITY.exit_none:
            exits.append(ack["exitReason"])
    result["ack_exit_reasons"] = sorted(set(exits))
    result["lease_expired_in_ack"] = (
        CONTINUITY.exit_lease_expired in exits)

    if run["acks_before_press"] == 0:
        raise SystemExit(
            "the epoch took no datagram before the press; the plane was not "
            "carrying anything and the hold proves nothing")

    disarm(wire, epoch)
    time.sleep(0.5)
    report, text = arrival_report(wire, epoch)
    result["arrival_line"] = text
    result["arrival"] = report

    if report is None:
        raise SystemExit("the epoch produced no arrival report to read")

    froze = (report["age"] > report["lease"]
             or report["starved"] > 0
             or result["lease_expired_in_ack"])
    result["froze"] = froze
    result["verdict"] = "freezes" if froze else "survives"
    # WAS THERE ANYTHING TO SEE. A hold that never let a backlog build did not
    # starve the application, and a healthy reading from it is the emptiness
    # of the rig rather than the health of the endpoint. Either the notifier
    # had to drain past the old cap, or the epoch had to die - anything else
    # is an unarmed instrument reporting success.
    result["rig_reproduced"] = bool(froze or report["burst"] > SOFT_CAP)
    if not result["rig_reproduced"]:
        raise SystemExit(
            f"the hold never starved the application: burst-max="
            f"{report['burst']} never passed the old cap of {SOFT_CAP} and "
            "the epoch survived. This run says nothing about the fix.")

    out = os.path.join(args.artifacts, "continuity-starvation.json")
    with open(out, "w") as handle:
        json.dump(result, handle, indent=2, sort_keys=True)
    print(json.dumps(result, indent=2, sort_keys=True))
    print(f"written: {out}")

    if result["verdict"] != args.expect:
        raise SystemExit(
            f"expected the hold to {args.expect}, and it {result['verdict']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
