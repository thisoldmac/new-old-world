#!/usr/bin/env python3
"""Exercise movement safety for Continuity V2 on a private mac99 clone.

This is deliberately not a product client. It drives the same versioned TCP
authority message and fixed-size UDP state datagrams as the host, records every
acknowledgement, then checks NOW wire liveness plus native emulated-device click
and motion after the first injected point. It refuses a resident without the
Continuity capability so a quarantine build cannot masquerade as a trial.
"""

import argparse
import importlib.util
import json
import os
import select
import socket
import struct
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.join(ROOT, "scripts", "probes"))
import nowwire  # noqa: E402


def load_qmp():
    path = os.path.join(ROOT, "tools", "local-cursor-mechanism.py")
    spec = importlib.util.spec_from_file_location("cursor_mechanism", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.Qmp


Qmp = load_qmp()
STATE = struct.Struct(">IHHIIIIhhIHHI")
ACK = struct.Struct(">IHHIIIIIHHIII")


def mouseloc(link):
    return dict(link.command("mouseloc", timeout=10).get("mouseloc") or [])


def next_control(link, kind, ident, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = link._pump(None, deadline)  # one persistent transport, same as probes
        if msg.get("type") == kind and msg.get("id") == ident:
            return msg
    raise TimeoutError(f"no {kind} id={ident}")


def next_unsolicited_exit(link, reason, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        msg = link._pump(None, deadline)
        if (msg.get("type") == "continuity.report"
                and "id" not in msg
                and msg.get("state") == "exited"
                and msg.get("reason") == reason):
            return msg
    raise TimeoutError(f"no unsolicited continuity exit reason={reason}")


def state_packet(nonce_hi, nonce_lo, epoch, seq, h, v, stamp):
    flags = 0x0001
    return STATE.pack(0x4E574331, 2, flags, nonce_hi, nonce_lo, epoch,
                      seq, h, v, 0, 30, 0, stamp)


def decode_ack(raw):
    if len(raw) != ACK.size:
        raise ValueError(f"ack is {len(raw)} bytes, expected {ACK.size}")
    values = ACK.unpack(raw)
    if values[0] != 0x4E574131 or values[1] != 2:
        raise ValueError(f"bad ack header {values[:2]}")
    return {
        "state": values[2], "nonceHi": values[3], "nonceLo": values[4],
        "epoch": values[5], "positionSequence": values[6],
        "buttonGeneration": values[7], "acceptedHz": values[8],
        "exitReason": values[9], "arrivalTicks": values[10],
        "applyTicks": values[11], "rejectedPackets": values[12],
    }


def send_until_applied(udp, nonce_hi, nonce_lo, epoch, seq, h, v,
                       timeout=2.0):
    deadline = time.time() + timeout
    attempts = 0
    while True:
        udp.send(state_packet(nonce_hi, nonce_lo, epoch, seq, h, v, seq))
        remaining = max(0.0, deadline - time.time())
        ready, _, _ = select.select([udp], [], [], min(0.10, remaining))
        if not ready:
            attempts += 1
            if time.time() >= deadline:
                raise TimeoutError(
                    f"position {seq} not applied after "
                    f"{attempts} sends without a confirming ACK")
            continue
        ack = decode_ack(udp.recv(ACK.size))
        if (ack["nonceHi"], ack["nonceLo"], ack["epoch"]) != (
                nonce_hi, nonce_lo, epoch):
            raise RuntimeError(f"mismatched ack at {seq}: {ack}")
        if ack["exitReason"] != 0:
            raise RuntimeError(f"resident exited at {seq}: {ack}")
        position_done = ack["positionSequence"] >= seq
        if ack["buttonGeneration"] != 0:
            raise RuntimeError(
                f"movement-only epoch unexpectedly applied a button: {ack}")
        if position_done and ack["state"] == 2:
            return ack, attempts
        attempts += 1
        if time.time() >= deadline:
            raise TimeoutError(
                f"position {seq} not applied after "
                f"{attempts + 1} replies: {ack}")
        time.sleep(0.01)


def drain_acks(udp, nonce_hi, nonce_lo, epoch):
    """Read every ACK currently queued without making state delivery wait.

    The product's UDP lane is absolute state, not request/reply. A prior rig
    waited for each ACK before sending the next point; one coalesced/lost ACK
    therefore stopped all keepalives and tested the deadman lease instead of
    sustained cursor control. The host never has that coupling.
    """
    out = []
    while True:
        ready, _, _ = select.select([udp], [], [], 0)
        if not ready:
            return out
        ack = decode_ack(udp.recv(ACK.size))
        if (ack["nonceHi"], ack["nonceLo"], ack["epoch"]) != (
                nonce_hi, nonce_lo, epoch):
            raise RuntimeError(f"mismatched streamed ACK: {ack}")
        if ack["exitReason"] != 0:
            raise RuntimeError(f"resident exited during stream: {ack}")
        out.append(ack)


def arm(link, ident, nonce_hi, nonce_lo, epoch):
    link._send({"type": "continuity.arm", "version": 2, "id": ident,
                "nonceHi": nonce_hi, "nonceLo": nonce_lo, "epoch": epoch,
                "requestedHz": 30, "leaseTicks": 90})
    report = next_control(link, "continuity.report", ident)
    if report.get("state") not in ("armed", "active"):
        raise RuntimeError(f"arm refused: {report}")
    return report


def disarm(link, ident, epoch):
    link._send({"type": "continuity.disarm", "version": 2,
                "id": ident, "epoch": epoch, "reason": "disabled"})
    return next_control(link, "continuity.report", ident)


def native_move(q, link, x=-140, y=-90):
    before_rows = mouseloc(link)
    before = (int(before_rows["x"]), int(before_rows["y"]))
    def move(dx, dy):
        q.cmd("input-send-event", {"events": [
            {"type": "rel", "data": {"axis": "x", "value": dx}},
            {"type": "rel", "data": {"axis": "y", "value": dy}},
        ]})
        time.sleep(0.8)
        result = mouseloc(link)
        return (int(result["x"]), int(result["y"]))

    after = move(x, y)
    if after == before:
        # The first optimistic-takeover move may have left the emulated
        # physical device against that edge even though Continuity's logical
        # point is elsewhere. Prove native motion in the opposite direction
        # rather than declaring a clamped device dead.
        after = move(-x, -y)
    if after == before:
        raise RuntimeError("native emulated input did not move after reset")
    return before, after


def native_click_takes_over(q, link):
    """Exercise the exact metal symptom and guest-wins rule after injection.

    Hold the physical button across several resident ticks, require the
    guest-side exit, then prove the cooperative NOW wire still answers.
    """
    q.cmd("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": True}},
    ]})
    time.sleep(0.12)
    q.cmd("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": False}},
    ]})
    takeover = next_unsolicited_exit(link, "guest-input")
    time.sleep(0.25)
    rows = mouseloc(link)
    if "x" not in rows or "y" not in rows:
        raise RuntimeError("wire did not answer after native click")
    return takeover, rows


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--qmp", required=True)
    ap.add_argument("--port", required=True, type=int)
    ap.add_argument("--via", required=True, choices=("pmu", "pmu-adb", "cuda"))
    ap.add_argument("--expect-build-prefix", required=True)
    ap.add_argument("--moves", type=int, default=180)
    ap.add_argument("--artifacts", required=True)
    args = ap.parse_args()
    # QMP resolves screendump filenames in QEMU's working directory. Keep the
    # evidence path stable when the caller supplies a repo-relative run dir.
    args.artifacts = os.path.abspath(args.artifacts)
    os.makedirs(args.artifacts, exist_ok=True)

    q = Qmp(args.qmp)
    link = nowwire.GuestLink.await_guest(args.port, timeout=180)
    build = str(link.hello.get("build") or "")
    if not build.startswith(args.expect_build_prefix):
        raise SystemExit(f"wrong guest build: {build!r}")
    ext = (link.command("mirror", timeout=30).get("mirror") or {}).get(
        "extension") or {}
    caps = int(ext.get("capabilities") or 0)
    if not caps & 0x200:
        raise SystemExit(
            f"Continuity capability is clear (caps={caps}); refusing a non-trial")

    nonce_hi, nonce_lo, epoch = 0x13579BDF, 0x2468ACE0, 1
    armed = arm(link, 7001, nonce_hi, nonce_lo, epoch)

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setblocking(False)
    udp.connect(("127.0.0.1", args.port))
    acks = []
    udp_replies = 0
    retries = 0
    points = ((220, 180), (520, 420), (340, 260), (610, 460))
    started = time.time()
    failure = None
    last_rows = None
    try:
        for seq in range(1, args.moves + 1):
            h, v = points[(seq - 1) % len(points)]
            udp.send(state_packet(nonce_hi, nonce_lo, epoch, seq, h, v, seq))
            streamed = drain_acks(udp, nonce_hi, nonce_lo, epoch)
            udp_replies += len(streamed)
            acks.extend(streamed)
            if seq == 1:
                last_rows = mouseloc(link)
            target = started + seq / 30.0
            if target > time.time():
                time.sleep(target - time.time())
        # The resident deliberately coalesces absolute state. Repeat only the
        # final point until one ACK observes it; delivery continues during an
        # ACK gap, so this cannot manufacture a lease expiry.
        h, v = points[(args.moves - 1) % len(points)]
        ack, attempts = send_until_applied(
            udp, nonce_hi, nonce_lo, epoch, args.moves, h, v)
        udp_replies += attempts + 1
        retries += attempts
        acks.append(ack)
        last_rows = mouseloc(link)
    except Exception as exc:
        failure = f"{type(exc).__name__}: {exc}"
        try:
            last_rows = mouseloc(link)
        except Exception:
            pass

    native_takeover = None
    disarmed = None
    reconnect_armed = reconnect_disarmed = None
    wire_reconnected = False
    native_before = native_after = None
    native_click_takeover = None
    native_click_rows = None
    if failure is None:
        try:
            # This is the exact first metal liveness check and guest-wins
            # boundary: after host movement, a physical click must revoke P9
            # and the independent wire must still answer.
            native_click_takeover, native_click_rows = native_click_takes_over(
                q, link)

            # Prove movement-only takeover independently on a fresh epoch.
            epoch = 2
            arm(link, 7002, nonce_hi, nonce_lo, epoch)
            ack, attempts = send_until_applied(
                udp, nonce_hi, nonce_lo, epoch, 1,
                points[-1][0], points[-1][1])
            acks.append(ack)
            udp_replies += attempts + 1
            retries += attempts
            takeover_before = mouseloc(link)
            takeover_x = int(takeover_before["x"])
            takeover_y = int(takeover_before["y"])
            q.cmd("input-send-event", {"events": [
                {"type": "rel", "data": {
                    "axis": "x", "value": 90 if takeover_x < 100 else -90}},
                {"type": "rel", "data": {
                    "axis": "y", "value": 60 if takeover_y < 100 else -60}},
            ]})
            native_takeover = next_unsolicited_exit(link, "guest-input")

            # A fresh movement epoch must disarm without any Event Manager or
            # cursor-manager recovery debt, then return to native motion.
            epoch = 3
            arm(link, 7003, nonce_hi, nonce_lo, epoch)
            ack, attempts = send_until_applied(
                udp, nonce_hi, nonce_lo, epoch, 1, points[-1][0], points[-1][1])
            acks.append(ack)
            udp_replies += attempts + 1
            retries += attempts
            mouseloc(link)
            disarmed = disarm(link, 7004, epoch)
            native_before, native_after = native_move(q, link)

            # Repeat movement across loss of the reliable authority lane. The
            # guest must revoke immediately, reconnect, accept native motion,
            # and arm afresh without endpoint reconstruction.
            epoch = 4
            reconnect_armed = arm(link, 7005, nonce_hi, nonce_lo, epoch)
            ack, attempts = send_until_applied(
                udp, nonce_hi, nonce_lo, epoch, 1, points[1][0], points[1][1])
            acks.append(ack)
            udp_replies += attempts + 1
            retries += attempts
            mouseloc(link)
            link.close()
            udp.close()
            link = nowwire.GuestLink.await_guest(args.port, timeout=90)
            reconnected_build = str(link.hello.get("build") or "")
            if reconnected_build != build:
                raise RuntimeError(
                    f"wrong guest after reconnect: {reconnected_build!r}")
            wire_reconnected = True
            native_move(q, link, x=110, y=70)

            epoch = 5
            reconnect_armed = arm(link, 7006, nonce_hi, nonce_lo, epoch)
            udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            udp.settimeout(2.0)
            udp.connect(("127.0.0.1", args.port))
            ack, attempts = send_until_applied(
                udp, nonce_hi, nonce_lo, epoch, 1, points[0][0], points[0][1])
            acks.append(ack)
            udp_replies += attempts + 1
            retries += attempts
            reconnect_disarmed = disarm(link, 7007, epoch)
        except Exception as exc:
            failure = f"{type(exc).__name__}: {exc}"

    # Capture register and frame evidence only after the live-lease checks.
    # This used to spend most of the 90-tick lease taking three register
    # samples and a screendump, then call the resulting lease exit a failed
    # native takeover. The artifacts are still useful for either outcome;
    # they are not allowed to perturb the behavior they document.
    registers = []
    for _ in range(3):
        registers.append(q.hmp("info registers"))
        time.sleep(0.25)
    open(os.path.join(args.artifacts, "registers.txt"), "w").write(
        "\n\n--- sample ---\n".join(registers))
    q.screendump(os.path.join(args.artifacts, "after-trial.ppm"))

    receipt = {
        "schema": "now-emulator-continuity-fault/v4",
        "via": args.via,
        "guestBuild": build,
        "residentCapabilities": caps,
        "residentFingerprint": ext.get("buildFingerprint"),
        "armed": armed,
        "movesRequested": args.moves,
        "acksReceived": len(acks),
        "udpReplies": udp_replies,
        "stateRetries": retries,
        "lastAck": acks[-1] if acks else None,
        "lastMouseRows": last_rows,
        "nativeClickWireAlive": native_click_rows is not None,
        "nativeClickTakeover": native_click_takeover,
        "nativeClickRows": native_click_rows,
        "nativeTakeover": native_takeover,
        "failure": failure,
        "disarmed": disarmed,
        "wireReconnectedAfterMovement": wire_reconnected,
        "reconnectArmed": reconnect_armed,
        "reconnectDisarmed": reconnect_disarmed,
        "nativeBefore": native_before,
        "nativeAfter": native_after,
    }
    with open(os.path.join(args.artifacts, "continuity-fault.json"), "w") as fh:
        json.dump(receipt, fh, indent=2)
    print(json.dumps(receipt, indent=2))
    udp.close()
    link.close()
    return 1 if failure else 0


if __name__ == "__main__":
    raise SystemExit(main())
