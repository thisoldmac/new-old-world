#!/usr/bin/env python3
"""Exercise Continuity V2 primary input on one private mac99 clone.

This is a fault instrument, not a product client. It drives the same TCP
authority and fixed-size UDP latest-state lane as NOW, and records five
independent boundaries: click, rapid click cycles, held drag, dead-man lease
release, and native guest-input takeover. Every held cycle must settle the
synthetic Cursor Device, leave MBState up, keep NOW's wire alive, and return
control to the emulated physical input device.
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
VERSION = 2
INSIDE = 0x0001
PRIMARY_DOWN = 0x0002


def mouseloc(link):
    return dict(link.command("mouseloc", timeout=10).get("mouseloc") or [])


def row_int(rows, name):
    if name not in rows:
        raise RuntimeError(f"mouseloc omitted {name!r}: {rows}")
    return int(rows[name])


def next_control(link, kind, ident, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        message = link._pump(None, deadline)
        if message.get("type") == kind and message.get("id") == ident:
            return message
    raise TimeoutError(f"no {kind} id={ident}")


def next_exit(link, reason=None, timeout=20):
    deadline = time.time() + timeout
    while time.time() < deadline:
        message = link._pump(None, deadline)
        if (message.get("type") == "continuity.report"
                and "id" not in message
                and message.get("state") == "exited"):
            if reason is None or message.get("reason") == reason:
                return message
            raise RuntimeError(
                f"expected Continuity exit {reason!r}, got {message}")
    raise TimeoutError(f"no Continuity exit reason={reason or 'any'}")


def encode_state(nonce_hi, nonce_lo, epoch, sequence, h, v,
                 button_generation, down, inside=True):
    flags = (INSIDE if inside else 0) | (PRIMARY_DOWN if down else 0)
    return STATE.pack(
        0x4E574331, VERSION, flags, nonce_hi, nonce_lo, epoch, sequence,
        h, v, button_generation, 30, 0,
        int(time.monotonic() * 60) & 0xFFFFFFFF)


def decode_ack(raw):
    if len(raw) != ACK.size:
        raise ValueError(f"ack is {len(raw)} bytes, expected {ACK.size}")
    values = ACK.unpack(raw)
    if values[0] != 0x4E574131 or values[1] != VERSION:
        raise ValueError(f"bad ack header {values[:2]}")
    return {
        "state": values[2], "nonceHi": values[3], "nonceLo": values[4],
        "epoch": values[5], "positionSequence": values[6],
        "buttonGeneration": values[7], "acceptedHz": values[8],
        "exitReason": values[9], "arrivalTicks": values[10],
        "applyTicks": values[11], "rejectedPackets": values[12],
    }


def drain_acks(udp, lease):
    replies = []
    while select.select([udp], [], [], 0)[0]:
        ack = decode_ack(udp.recv(ACK.size))
        if (ack["nonceHi"], ack["nonceLo"], ack["epoch"]) != lease:
            raise RuntimeError(f"mismatched acknowledgement: {ack}")
        if ack["exitReason"] != 0:
            raise RuntimeError(f"guest exited during active stream: {ack}")
        replies.append(ack)
    return replies


def send_until_applied(udp, lease, sequence, h, v, generation, down,
                       timeout=3.0):
    nonce_hi, nonce_lo, epoch = lease
    packet = encode_state(nonce_hi, nonce_lo, epoch, sequence, h, v,
                          generation, down)
    deadline = time.time() + timeout
    replies = []
    sends = 0
    while time.time() < deadline:
        udp.send(packet)
        sends += 1
        ready = select.select([udp], [], [], min(0.08, deadline - time.time()))[0]
        if not ready:
            continue
        ack = decode_ack(udp.recv(ACK.size))
        replies.append(ack)
        if (ack["nonceHi"], ack["nonceLo"], ack["epoch"]) != lease:
            # UDP is absolute state. A delayed ACK from the just-retired
            # epoch is expected and the product host ignores it by lease.
            continue
        if ack["exitReason"] != 0:
            raise RuntimeError(f"guest exited before transition settled: {ack}")
        if (ack["state"] == 2
                and ack["positionSequence"] >= sequence
                and ack["buttonGeneration"] == generation):
            return ack, sends, replies
    raise TimeoutError(
        f"state seq={sequence} generation={generation} down={down} "
        f"not applied after {sends} sends; last={replies[-1] if replies else None}")


def arm(link, ident, lease, fast_pump=False):
    nonce_hi, nonce_lo, epoch = lease
    link._send({
        "type": "continuity.arm", "version": VERSION, "id": ident,
        "nonceHi": nonce_hi, "nonceLo": nonce_lo, "epoch": epoch,
        "requestedHz": 30, "leaseTicks": 90, "fastPump": fast_pump,
    })
    report = next_control(link, "continuity.report", ident)
    if report.get("state") not in ("armed", "active"):
        raise RuntimeError(f"arm refused: {report}")
    return report


def disarm(link, ident, epoch):
    link._send({
        "type": "continuity.disarm", "version": VERSION, "id": ident,
        "epoch": epoch, "reason": "disabled",
    })
    return next_control(link, "continuity.report", ident)


def assert_released(link, expected_generation, expected_point=None):
    rows = mouseloc(link)
    if row_int(rows, "button down") != 0:
        raise RuntimeError(f"guest button remained down: {rows}")
    if row_int(rows, "button pending up") != 0:
        raise RuntimeError(f"guest retained a manager-up debt: {rows}")
    if row_int(rows, "button generation") != expected_generation:
        raise RuntimeError(
            f"guest settled generation {rows.get('button generation')}, "
            f"expected {expected_generation}")
    if expected_point is not None:
        actual = (row_int(rows, "x"), row_int(rows, "y"))
        if actual != expected_point:
            raise RuntimeError(
                f"final pointer is {actual}, expected {expected_point}")
    return rows


def native_move(qmp, link, dx, dy):
    before_rows = mouseloc(link)
    before = (row_int(before_rows, "x"), row_int(before_rows, "y"))
    qmp.cmd("input-send-event", {"events": [
        {"type": "rel", "data": {"axis": "x", "value": dx}},
        {"type": "rel", "data": {"axis": "y", "value": dy}},
    ]})
    time.sleep(0.6)
    after_rows = mouseloc(link)
    after = (row_int(after_rows, "x"), row_int(after_rows, "y"))
    if after == before:
        qmp.cmd("input-send-event", {"events": [
            {"type": "rel", "data": {"axis": "x", "value": -dx}},
            {"type": "rel", "data": {"axis": "y", "value": -dy}},
        ]})
        time.sleep(0.6)
        after_rows = mouseloc(link)
        after = (row_int(after_rows, "x"), row_int(after_rows, "y"))
    if after == before:
        raise RuntimeError("native emulated pointer did not recover")
    return {"before": before, "after": after, "rows": after_rows}


def run_click(link, udp, lease, ident, fast_pump=False):
    armed = arm(link, ident, lease, fast_pump)
    down, down_sends, _ = send_until_applied(
        udp, lease, 1, 360, 280, 1, True)
    up, up_sends, _ = send_until_applied(
        udp, lease, 2, 360, 280, 2, False)
    rows = assert_released(link, 2, (360, 280))
    stopped = disarm(link, ident + 1, lease[2])
    return {"armed": armed, "down": down, "up": up,
            "sends": down_sends + up_sends, "rows": rows,
            "disarmed": stopped}


def run_click_burst(link, udp, lease, ident, cycles=16, fast_pump=False):
    armed = arm(link, ident, lease, fast_pump)
    sequence = 0
    generation = 0
    sends = 0
    last_down = None
    last_up = None
    for cycle in range(cycles):
        point = (320 + cycle % 4, 250 + cycle % 3)
        sequence += 1
        generation += 1
        last_down, count, _ = send_until_applied(
            udp, lease, sequence, *point, generation, True)
        sends += count
        sequence += 1
        generation += 1
        last_up, count, _ = send_until_applied(
            udp, lease, sequence, *point, generation, False)
        sends += count
    rows = assert_released(link, generation)
    stopped = disarm(link, ident + 1, lease[2])
    return {"armed": armed, "cycles": cycles, "transitions": generation,
            "lastDown": last_down, "lastUp": last_up, "sends": sends,
            "rows": rows, "disarmed": stopped}


def run_drag(link, udp, lease, ident, fast_pump=False):
    armed = arm(link, ident, lease, fast_pump)
    down, down_sends, replies = send_until_applied(
        udp, lease, 1, 280, 220, 1, True)
    points = [(280 + i * 5, 220 + i * 3) for i in range(1, 31)]
    started = time.time()
    for sequence, point in enumerate(points, 2):
        udp.send(encode_state(*lease, sequence, *point, 1, True))
        replies.extend(drain_acks(udp, lease))
        target = started + (sequence - 1) / 30.0
        if target > time.time():
            time.sleep(target - time.time())
    final_sequence = len(points) + 2
    final_point = points[-1]
    up, up_sends, up_replies = send_until_applied(
        udp, lease, final_sequence, *final_point, 2, False)
    replies.extend(up_replies)
    rows = assert_released(link, 2, final_point)
    stopped = disarm(link, ident + 1, lease[2])
    return {"armed": armed, "down": down, "up": up,
            "streamedPoints": len(points), "streamAcks": len(replies),
            "sends": down_sends + len(points) + up_sends, "rows": rows,
            "disarmed": stopped}


def run_lease_release(link, udp, lease, ident, fast_pump=False):
    armed = arm(link, ident, lease, fast_pump)
    down, sends, _ = send_until_applied(
        udp, lease, 1, 420, 320, 1, True)
    exited = next_exit(link, "lease-expired", timeout=10)
    rows = assert_released(link, int(exited["appliedButtonGeneration"]))
    return {"armed": armed, "down": down, "sends": sends,
            "exit": exited, "rows": rows}


def run_native_takeover(qmp, link, udp, lease, ident, fast_pump=False):
    armed = arm(link, ident, lease, fast_pump)
    down, sends, _ = send_until_applied(
        udp, lease, 1, 460, 340, 1, True)
    qmp.cmd("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": True}},
        {"type": "rel", "data": {"axis": "x", "value": -75}},
        {"type": "rel", "data": {"axis": "y", "value": -55}},
    ]})
    time.sleep(0.12)
    qmp.cmd("input-send-event", {"events": [
        {"type": "btn", "data": {"button": "left", "down": False}},
    ]})
    exited = next_exit(link, timeout=10)
    if exited.get("reason") not in ("guest-input", "lease-expired"):
        raise RuntimeError(f"unexpected native-takeover exit: {exited}")
    rows = assert_released(link, int(exited["appliedButtonGeneration"]))
    return {"armed": armed, "down": down, "sends": sends,
            "exit": exited, "rows": rows,
            "guestInputObserved": exited.get("reason") == "guest-input",
            "emulatorLimitation": None if exited.get("reason") == "guest-input"
            else "QMP physical input was not observable while the synthetic "
                 "Cursor Device was held; dead-man lease release was observed"}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qmp", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--via", required=True,
                        choices=("pmu", "pmu-adb", "cuda"))
    parser.add_argument("--expect-build-prefix", required=True)
    parser.add_argument("--artifacts", required=True)
    parser.add_argument("--fast-pump", action="store_true",
                        help="arm every test epoch with experimental Fast Pump")
    args = parser.parse_args()
    args.artifacts = os.path.abspath(args.artifacts)
    os.makedirs(args.artifacts, exist_ok=True)

    qmp = Qmp(args.qmp)
    link = nowwire.GuestLink.await_guest(args.port, timeout=180)
    build = str(link.hello.get("build") or "")
    if not build.startswith(args.expect_build_prefix):
        raise SystemExit(f"wrong guest build: {build!r}")
    extension = (link.command("mirror", timeout=30).get("mirror") or {}).get(
        "extension") or {}
    capabilities = int(extension.get("capabilities") or 0)
    if not capabilities & 0x200:
        raise SystemExit(
            f"Continuity capability is clear (caps={capabilities})")

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setblocking(False)
    udp.connect(("127.0.0.1", args.port))
    nonce_hi, nonce_lo = 0x51A7C0DE, 0x0DDC0FFE
    receipt = {
        "schema": "now-emulator-direct-pointer/v2",
        "via": args.via,
        "guestBuild": build,
        "residentCapabilities": capabilities,
        "residentFingerprint": extension.get("buildFingerprint"),
        "fastPump": args.fast_pump,
    }
    active_epoch = None
    try:
        active_epoch = 101
        receipt["click"] = run_click(
            link, udp, (nonce_hi, nonce_lo, active_epoch), 8101,
            args.fast_pump)
        receipt["nativeAfterClick"] = native_move(qmp, link, -90, -60)
        active_epoch = 102
        receipt["rapidClicks"] = run_click_burst(
            link, udp, (nonce_hi, nonce_lo, active_epoch), 8111,
            fast_pump=args.fast_pump)
        active_epoch = 103
        receipt["drag"] = run_drag(
            link, udp, (nonce_hi, nonce_lo, active_epoch), 8121,
            args.fast_pump)
        receipt["nativeAfterDrag"] = native_move(qmp, link, 90, 60)
        active_epoch = 104
        receipt["leaseRelease"] = run_lease_release(
            link, udp, (nonce_hi, nonce_lo, active_epoch), 8131,
            args.fast_pump)
        receipt["nativeAfterLease"] = native_move(qmp, link, -70, 45)
        active_epoch = 105
        receipt["nativeTakeover"] = run_native_takeover(
            qmp, link, udp, (nonce_hi, nonce_lo, active_epoch), 8141,
            args.fast_pump)
        receipt["wireAfterTakeover"] = mouseloc(link)
        receipt["failure"] = None
    except Exception as error:
        receipt["failure"] = f"{type(error).__name__}: {error}"
        if active_epoch is not None:
            try:
                for _ in range(3):
                    udp.send(encode_state(
                        nonce_hi, nonce_lo, active_epoch, 0x7FFFFFFF,
                        0, 0, 0x7FFFFFFF, False, inside=False))
                disarm(link, 8199, active_epoch)
            except Exception as cleanup_error:
                receipt["cleanupFailure"] = (
                    f"{type(cleanup_error).__name__}: {cleanup_error}")

    try:
        receipt["finalWire"] = mouseloc(link)
    except Exception as error:
        receipt["finalWireFailure"] = f"{type(error).__name__}: {error}"
    with open(os.path.join(args.artifacts, "registers.txt"), "w") as handle:
        handle.write(qmp.hmp("info registers"))
    qmp.screendump(os.path.join(args.artifacts, "after-direct-pointer.ppm"))
    with open(os.path.join(args.artifacts, "direct-pointer.json"), "w") as handle:
        json.dump(receipt, handle, indent=2)
    print(json.dumps(receipt, indent=2))
    udp.close()
    link.close()
    return 1 if receipt.get("failure") else 0


if __name__ == "__main__":
    raise SystemExit(main())
