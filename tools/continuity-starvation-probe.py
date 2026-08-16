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
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
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

ARRIVAL_LINE = re.compile(
    r"continuity arrival epoch=(?P<epoch>\d+) age=(?P<age>\d+) "
    r"lease=(?P<lease>\d+) ticks .*?"
    r"drain: burst-max=(?P<burst>\d+) handoff=(?P<handoff>\d+) "
    r"starved=(?P<starved>\d+) owed=(?P<owed>\d+)")


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


def next_control(link, kind, ident, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = link._pump(None, deadline)
        if msg.get("type") == kind and msg.get("id") == ident:
            return msg
    raise TimeoutError(f"no {kind} id={ident}")


def arm(link, ident, nonce_hi, nonce_lo, epoch, lease_ticks):
    link._send({"type": "continuity.arm", "version": CONTINUITY.version,
                "id": ident, "nonceHi": nonce_hi, "nonceLo": nonce_lo,
                "epoch": epoch, "requestedHz": 60,
                "leaseTicks": lease_ticks})
    report = next_control(link, "continuity.report", ident)
    if report.get("state") not in ("armed", "active"):
        raise RuntimeError(f"arm refused: {report}")
    return report


def disarm(link, ident, epoch):
    link._send({"type": "continuity.disarm", "version": CONTINUITY.version,
                "id": ident, "epoch": epoch, "reason": "disabled"})
    return next_control(link, "continuity.report", ident)


def mirror_log(link, lines=40):
    rows = link.command(f"tail {lines} mirror", timeout=30)
    for key in ("tail", "log", "lines"):
        if key in rows:
            value = rows[key]
            return value if isinstance(value, list) else [str(value)]
    return [json.dumps(rows)]


def arrival_report(link, epoch, lines=40):
    for line in reversed(mirror_log(link, lines)):
        text = line if isinstance(line, str) else json.dumps(line)
        found = ARRIVAL_LINE.search(text)
        if found and int(found.group("epoch")) == epoch:
            return {k: int(v) for k, v in found.groupdict().items()}, text
    return None, None


def hold_menu(udp, link, nonce_hi, nonce_lo, epoch, hold_s, hz, acks):
    """Press a menu title, keep sending through the hold, release safely."""
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
    while time.time() - press_at < hold_s:
        # A point or two of jitter inside the title: a live host never sends a
        # perfectly static stream, and a coalescing resident may ignore one.
        wobble = int((time.time() - press_at) * 4) % 3
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
    ap.add_argument("--lease-ticks", type=int, default=90,
                    help="what the real host arms (90 ticks = 1.5s)")
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--expect", choices=("survives", "freezes"),
                    default="survives",
                    help="'freezes' inverts the verdict, for watching a "
                         "mutated build fail the way the incident did")
    args = ap.parse_args()
    os.makedirs(args.artifacts, exist_ok=True)

    result = {"expect": args.expect, "hold_requested_s": args.hold,
              "lease_ticks": args.lease_ticks}
    link = nowwire.GuestLink.await_guest(args.port, timeout=180)
    result["build"] = str(link.hello.get("build") or "")

    ext = (link.command("mirror", timeout=30).get("mirror") or {}).get(
        "extension") or {}
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
    arm(link, 8101, nonce_hi, nonce_lo, 1, args.lease_ticks)
    for seq in range(1, 31):
        udp.send(state(nonce_hi, nonce_lo, 1, seq, 300, 240, 0,
                       CONTINUITY.flag_inside, seq))
        drain_acks(udp, nonce_hi, nonce_lo, 1, acks)
        time.sleep(1.0 / args.hz)
    disarm(link, 8102, 1)
    time.sleep(0.5)
    warmup, warmup_text = arrival_report(link, 1)
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

    # --- the run itself ---
    epoch = 2
    acks = []
    exits = []
    arm(link, 8103, nonce_hi, nonce_lo, epoch, args.lease_ticks)
    run = hold_menu(udp, link, nonce_hi, nonce_lo, epoch,
                    args.hold, args.hz, acks)
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

    disarm(link, 8104, epoch)
    time.sleep(0.5)
    report, text = arrival_report(link, epoch)
    result["arrival_line"] = text
    result["arrival"] = report

    if report is None:
        raise SystemExit("the epoch produced no arrival report to read")

    froze = (report["age"] > report["lease"]
             or report["starved"] > 0
             or result["lease_expired_in_ack"])
    result["froze"] = froze
    result["verdict"] = "freezes" if froze else "survives"

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
