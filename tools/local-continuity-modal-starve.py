#!/usr/bin/env python3
"""What of CONTINUITY survives a foreign application's modal alert?

    tools/local-continuity-modal-starve.py --qmp /private/tmp/nowvm-x/qmp.sock \\
        --port 19081 --anchor 19080 --expect-build 4e7f6404 \\
        --artifacts /private/tmp/nowvm-x/modal

DIAGNOSTIC, `local-*` like its neighbours: one emulator clone, one desk,
ships to nobody.

WHY IT EXISTS. On 2026-08-16 Michelle launched Internet Explorer on the
guest with too little memory; its out-of-memory alert came up in IE's own
context and Continuity went dead — no pointer, no clicks, and no way to
click the alert's own button to get out of it. `local-modal-starve.py`
already answers "is NOW starved or merely slow" for the SCENE plane. This
answers the three questions that plane cannot:

  1. **Do the guest's acknowledgements stop?**  They are sent from the
     application's cooperative pump (`continuity_intake.c :: try_send_ack`),
     so they are expected to; counting them is the control, not the finding.
  2. **Was anything APPLIED while starved?**  The ACK carries
     `arrivalTicks`, and this run reads it as the guest's own dating of the
     last datagram that reached the resident's apply. An `arrivalTicks`
     still at its pre-modal value after the modal is dismissed means not one
     of the datagrams sent through the window was ever applied.

     IT DOES NOT ANSWER WHETHER THE OT NOTIFIER RAN, and the first version
     of this file claimed it did. `prepare_ack` fills that field from
     `shared->last_arrival_ticks`, which the RESIDENT writes when it
     consumes a packet — not from `shared->arrival_ticks`, which the
     notifier writes when it accepts one. So a stale stamp is consistent
     both with a notifier that never ran and with a notifier that published
     into a cell nobody read. Nothing that survives to the wire distinguishes
     them today; answering it needs a notifier-side counter in the report,
     and that is written down rather than guessed.
  3. **Can the person CLICK THE ALERT'S OWN BUTTON over the wire?**  The
     self-rescue question. Continuity presses are sent as ordinary state
     datagrams; if the resident's button task can post them without the
     application, the alert dismisses and the wire returns with no help
     from this instrument. `--ok-point` is where its default button is.

HOW THE MODAL IS RAISED, and why in two steps. `tools/stage-orphan-doc.py`
plus a Finder open raises the unknown-creator alert
(docs/raising-the-unknown-creator-modal.md), but with NOW frontmost the
alert is drawn BEHIND it and does not starve anything — measured here, and
the reason the first attempt at this run read as a healthy machine. The
starving case is the one Michelle met: the modal's owner is FRONTMOST. So
the alert is raised first, while the wire still works, and the Finder is
brought forward second. That second request is sent and never read: the
application it is addressed to has stopped answering, which is the point.

WHAT IT REFUSES. A guest whose hello build is not `--expect-build` (every
QEMU guest on this Mac sees the host as 10.0.2.2 and any session's VM can
answer this listener — AGENTS.md), and a resident without the Continuity
capability bit.
"""

import argparse
import importlib.util
import json
import os
import select
import socket
import subprocess
import sys
import time
from pathlib import Path

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
# ORDER MATTERS: there are two modules called `nowwire` in this tree, and
# only scripts/probes' one has the GuestLink used below. tools/ goes on the
# path second so its namesake cannot shadow it.
sys.path.insert(0, os.path.join(ROOT, "tools"))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402
from continuity_contract import load as load_continuity_contract  # noqa: E402

CONTINUITY = load_continuity_contract(Path(ROOT))
ACK = CONTINUITY.ack_struct
TICKS_PER_SECOND = 60.0


def load_qmp():
    path = os.path.join(ROOT, "tools", "local-cursor-mechanism.py")
    spec = importlib.util.spec_from_file_location("cursor_mechanism", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Qmp


def state_packet(nonce, epoch, seq, h, v, generation=0, flags=None,
                 previous_generation=0, previous_flags=0):
    if flags is None:
        flags = CONTINUITY.flag_inside
    return CONTINUITY.encode_state(
        nonce[0], nonce[1], epoch, seq, h, v, generation, 30, seq, flags,
        previous_generation, previous_flags)


def drain_acks(udp, nonce, epoch, out):
    """Every ACK queued right now, timestamped by the host. Never blocks."""
    while True:
        ready, _, _ = select.select([udp], [], [], 0)
        if not ready:
            return out
        try:
            ack = CONTINUITY.decode_ack(udp.recv(ACK.size))
        except ValueError:
            continue
        if (ack["nonceHi"], ack["nonceLo"], ack["epoch"]) != (
                nonce[0], nonce[1], epoch):
            continue
        ack["hostUptime"] = time.time()
        out.append(ack)


def wait_for_ack(udp, nonce, epoch, out, seconds):
    deadline = time.time() + seconds
    start = len(out)
    while time.time() < deadline:
        drain_acks(udp, nonce, epoch, out)
        if len(out) > start:
            return out[-1]
        time.sleep(0.02)
    return None


def ppm_region(path, left, top, right, bottom):
    """The raw bytes of one rectangle of a QMP screendump.

    THE ONLY HONEST ORACLE FOR "DID THE ALERT GO AWAY". The first version of
    this run asked whether acknowledgements resumed after the click, and
    called that self-rescue — but on a modal that TAXES rather than starves,
    acknowledgements never stopped, so it answered yes while the screendump
    beside it showed the alert exactly where it was. A question whose answer
    is the same when nothing happened is not a measurement.

    The rectangle is the alert's own text, not its button: the Continuity
    cursor is parked on the button by construction, so a region containing it
    would change whether or not the click landed.
    """
    with open(path, "rb") as handle:
        data = handle.read()
    fields = []
    index = 0
    while len(fields) < 4:
        end = data.index(b"\n", index)
        line = data[index:end]
        index = end + 1
        if line.startswith(b"#"):
            continue
        fields.extend(line.split())
    width, height = int(fields[1]), int(fields[2])
    pixels = data[index:]
    out = bytearray()
    for row in range(max(0, top), min(height, bottom)):
        start = (row * width + max(0, left)) * 3
        out += pixels[start:start + (min(width, right) - max(0, left)) * 3]
    return bytes(out)


def guest_ticks(link, timeout=30):
    snap = link.command("axsnap", timeout=timeout)
    front = snap["axsnap"]["front"]
    return int(front["stampTicks"]), str(front["name"])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--port", required=True, type=int, help="the wire port")
    ap.add_argument("--anchor", required=True, type=int)
    ap.add_argument("--expect-build", required=True)
    ap.add_argument("--artifacts", required=True)
    ap.add_argument("--modal-seconds", type=float, default=30.0)
    ap.add_argument("--marker-lead", type=float, default=8.0,
                    help="how long before the dismissal the marker datagram "
                         "is sent; the whole notifier measurement is this "
                         "number turned into ticks by the guest")
    ap.add_argument("--ok-point", default="542,230",
                    help="the alert's default button, in guest screen points")
    ap.add_argument("--self-rescue-seconds", type=float, default=12.0)
    ap.add_argument("--alert-region", default="230,120,500,200",
                    help="left,top,right,bottom of the alert's TEXT, the "
                         "rectangle the self-rescue verdict is read from")
    args = ap.parse_args()

    artifacts = os.path.abspath(args.artifacts)
    os.makedirs(artifacts, exist_ok=True)
    ok_h, ok_v = (int(part) for part in args.ok_point.split(","))
    region = tuple(int(part) for part in args.alert_region.split(","))
    qmp = load_qmp()(args.qmp)
    report = {"okPoint": [ok_h, ok_v], "modalSeconds": args.modal_seconds}

    def shot(name):
        path = os.path.join(artifacts, name + ".ppm")
        qmp.cmd("screendump", {"filename": path})
        return path

    link = nowwire.GuestLink.await_guest(args.port, timeout=180)
    build = str(link.hello.get("build") or "")
    if not build.startswith(args.expect_build):
        raise SystemExit(f"wrong guest build: {build!r}")
    report["build"] = build
    extension = (link.command("mirror", timeout=30).get("mirror") or {}).get(
        "extension") or {}
    caps = int(extension.get("capabilities") or 0)
    if not caps & 0x200:
        raise SystemExit(f"Continuity capability clear (caps={caps})")
    report["extension"] = extension

    nonce = (0x51DE1CE0, 0x0BADF00D)
    epoch = 1
    link._send({"type": "continuity.arm", "version": CONTINUITY.version,
                "id": 9001, "nonceHi": nonce[0], "nonceLo": nonce[1],
                "epoch": epoch, "requestedHz": 30, "leaseTicks": 90})
    deadline = time.time() + 30
    armed = None
    while time.time() < deadline:
        message = link._pump(None, deadline)
        if message.get("type") == "continuity.report" \
                and message.get("id") == 9001:
            armed = message
            break
    if armed is None or armed.get("state") not in ("armed", "active"):
        raise SystemExit(f"arm refused: {armed}")
    report["arm"] = armed

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setblocking(False)
    udp.connect(("127.0.0.1", args.port))
    acks = []

    # Baseline: the healthy machine, so every number below has a control.
    sequence = 0
    for point in ((300, 200), (360, 240), (420, 280)):
        sequence += 1
        udp.send(state_packet(nonce, epoch, sequence, point[0], point[1]))
        wait_for_ack(udp, nonce, epoch, acks, 3)
    if not acks:
        raise SystemExit("no acknowledgement on a healthy machine: "
                         "nothing below would mean anything")
    baseline_ticks, front = guest_ticks(link)
    try:
        link.command("wirestat", {"target": "reset"}, timeout=20)
    except Exception:
        pass
    report["baseline"] = {"acks": len(acks), "lastAck": acks[-1],
                          "guestTicks": baseline_ticks, "front": front}
    shot("baseline")

    # NOW MUST BE FRONTMOST WHEN THE ALERT IS RAISED, and this is not
    # tidiness. Raised with the Finder already in front, the same alert is a
    # TAX (measured here: 42 acknowledgements through a 30 s window, the
    # pointer still moving). Raised behind NOW and only then brought
    # forward — which is the shape a person meets, because they were using
    # NOW when the other application interrupted them — it wedges. The
    # Notification Manager's "the Finder needs your attention" bar is the
    # visible difference between the two.
    try:
        link.command("front", {"target": "New Old World"}, timeout=30)
    except Exception as exc:
        report["frontNOW"] = f"{type(exc).__name__}: {exc}"
    time.sleep(2)

    # Raise the alert with NOW still frontmost: it draws behind, and the
    # wire keeps working, so this step is observable.
    stage = subprocess.run(
        [sys.executable, os.path.join(ROOT, "tools", "stage-orphan-doc.py")],
        env=dict(os.environ, NOW_ANCHOR_PORT=str(args.anchor)),
        capture_output=True, text=True, cwd=ROOT)
    report["stage"] = {"returncode": stage.returncode,
                       "stdout": stage.stdout[-800:],
                       "stderr": stage.stderr[-800:]}
    if stage.returncode:
        raise SystemExit("could not stage the orphan document")
    link.send_async("script", {
        "source": 'tell application "Finder" to open item '
                  '"Orphan Document" of desktop'})
    time.sleep(12)
    alert_behind = shot("alert-behind")

    # Now the starving arrangement: the modal's owner in front.
    link.send_async("front", {"target": "Finder"})   # never answered
    starve_started = time.time()
    acks_before_modal = len(acks)
    sent_during = 0
    marker_sequence = None
    marker_uptime = None
    self_rescue = {"attempted": False, "worked": None}

    end = starve_started + args.modal_seconds
    rescue_at = end - args.self_rescue_seconds
    marker_at = end - args.marker_lead
    generation = 0
    while time.time() < end:
        sequence += 1
        now = time.time()
        if marker_sequence is None and now >= marker_at:
            marker_sequence = sequence
            marker_uptime = now
        udp.send(state_packet(nonce, epoch, sequence, 640, 400))
        sent_during += 1
        if not self_rescue["attempted"] and now >= rescue_at:
            self_rescue["attempted"] = True
            # A press and a release at the alert's own OK button, exactly as
            # the host would send them: one generation, previous carried
            # beside it.
            generation += 1
            udp.send(state_packet(
                nonce, epoch, sequence, ok_h, ok_v, generation,
                CONTINUITY.flag_inside | CONTINUITY.flag_primary_down))
            time.sleep(0.15)
            sequence += 1
            udp.send(state_packet(
                nonce, epoch, sequence, ok_h, ok_v, generation + 1,
                CONTINUITY.flag_inside, generation,
                CONTINUITY.flag_primary_down))
            generation += 1
        drain_acks(udp, nonce, epoch, acks)
        time.sleep(1 / 30.0)
    drain_acks(udp, nonce, epoch, acks)
    acks_during = len(acks) - acks_before_modal
    modal_front = shot("modal-front")

    # Did the click alone bring it back?  No datagrams for the marker lead's
    # last stretch, so the notifier question stays clean either way.
    quiet_started = time.time()
    while time.time() - quiet_started < 3.0:
        drain_acks(udp, nonce, epoch, acks)
        time.sleep(0.05)
    self_rescue["acksAfterClick"] = len(acks) - acks_before_modal - acks_during
    after_click = shot("after-click")
    before_pixels = ppm_region(modal_front, *region)
    self_rescue["alertRegionChanged"] = \
        ppm_region(after_click, *region) != before_pixels
    self_rescue["worked"] = self_rescue["alertRegionChanged"]
    report["alertRaised"] = ppm_region(alert_behind, *region) != ppm_region(
        os.path.join(artifacts, "baseline.ppm"), *region)

    dismissed_by = "self-rescue"
    if not self_rescue["worked"]:
        qmp.cmd("send-key", {"keys": [{"type": "qcode", "data": "ret"}]})
        dismissed_by = "qmp send-key ret"
    dismissed_uptime = time.time()
    report["dismissedBy"] = dismissed_by

    first_after = wait_for_ack(udp, nonce, epoch, acks, 20)
    report["firstAckAfterDismissal"] = first_after
    time.sleep(3)
    shot("dismissed")

    # The notifier verdict.  The marker's arrival stamp is the guest's own
    # dating of when it read that datagram.
    verdict = {"markerSequence": marker_sequence,
               "markerSecondsBeforeDismissal":
                   None if marker_uptime is None
                   else dismissed_uptime - marker_uptime}
    if first_after is not None and marker_uptime is not None:
        try:
            after_ticks, _ = guest_ticks(link, timeout=40)
            verdict["guestTicksAfterDismissal"] = after_ticks
            verdict["arrivalTicks"] = first_after["arrivalTicks"]
            behind = (after_ticks - first_after["arrivalTicks"]) \
                / TICKS_PER_SECOND
            verdict["arrivalSecondsBeforeThatReading"] = behind
            verdict["appliedDuringModal"] = \
                first_after["arrivalTicks"] > baseline_ticks
            verdict["note"] = (
                "arrivalTicks is the last APPLIED datagram's stamp, not the "
                "last RECEIVED one; it cannot decide whether the OT notifier "
                "ran while starved")
        except Exception as exc:            # the wire may still be settling
            verdict["error"] = f"{type(exc).__name__}: {exc}"
    try:
        report["wirestat"] = link.command("wirestat", timeout=40)
    except Exception as exc:
        report["wirestat"] = f"{type(exc).__name__}: {exc}"
    report["notifier"] = verdict
    report["acks"] = {"beforeModal": acks_before_modal,
                      "duringModal": acks_during,
                      "sentDuringModal": sent_during,
                      "total": len(acks)}
    report["selfRescue"] = self_rescue

    try:
        link._send({"type": "continuity.disarm",
                    "version": CONTINUITY.version, "id": 9002,
                    "epoch": epoch, "reason": "disabled"})
    except Exception:
        pass
    path = os.path.join(artifacts, "modal-starve.json")
    with open(path, "w") as handle:
        json.dump(report, handle, indent=2, sort_keys=True)
    print(json.dumps(report, indent=2, sort_keys=True))
    print(f"\nwritten: {path}")


if __name__ == "__main__":
    main()
