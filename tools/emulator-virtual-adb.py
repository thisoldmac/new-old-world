#!/usr/bin/env python3
"""Prove the opt-in Continuity virtual-ADB packet path on CUDA.

The product host never sends `virtualADB`. This instrument supplies tiny QMP
relative movements solely as ADB autopoll carriers, requires the guest pointer
to reach an absolute UDP target without a Cursor Device position apply, then
sends a larger native delta and requires optimistic guest-side takeover.
"""

import argparse
import importlib.util
import json
import os
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


def load_direct_pointer():
    path = os.path.join(ROOT, "tools", "emulator-direct-pointer.py")
    spec = importlib.util.spec_from_file_location("direct_pointer", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


DP = load_direct_pointer()
CONTINUITY = load_continuity_contract(Path(ROOT))


def arm(link, ident, lease):
    nonce_hi, nonce_lo, epoch = lease
    link._send({
        "type": "continuity.arm", "version": CONTINUITY.version, "id": ident,
        "nonceHi": nonce_hi, "nonceLo": nonce_lo, "epoch": epoch,
        "requestedHz": 30, "leaseTicks": 180, "fastPump": True,
        "virtualADB": True,
    })
    report = DP.next_control(link, "continuity.report", ident)
    if report.get("state") not in ("armed", "active"):
        raise RuntimeError(f"virtual ADB arm refused: {report}")
    return report


def carrier(qmp):
    qmp.cmd("input-send-event", {"events": [
        {"type": "rel", "data": {"axis": "x", "value": 1}},
    ]})


def drive_target(qmp, link, udp, lease, sequence, target,
                 generation=0, down=False, timeout=8.0):
    packet = DP.encode_state(
        *lease, sequence, *target, generation, down)
    deadline = time.time() + timeout
    acknowledgements = []
    carriers = 0
    while time.time() < deadline:
        udp.send(packet)
        time.sleep(0.04)
        carrier(qmp)
        carriers += 1
        ready = select.select([udp], [], [], 0.12)[0]
        while ready:
            ack = DP.decode_ack(udp.recv(DP.ACK.size))
            if (ack["nonceHi"], ack["nonceLo"], ack["epoch"]) == lease:
                acknowledgements.append(ack)
                if ack["exitReason"] != CONTINUITY.exit_none:
                    raise RuntimeError(f"virtual ADB exited early: {ack}")
                if (ack["state"] == CONTINUITY.ack_active
                        and ack["positionSequence"] >= sequence
                        and ack["buttonGeneration"] == generation):
                    return {
                        "ack": ack,
                        "carriers": carriers,
                        "acknowledgements": acknowledgements,
                    }
            ready = select.select([udp], [], [], 0)[0]
    rows = DP.mouseloc(link)
    raise TimeoutError(
        f"virtual ADB did not settle seq={sequence} target={target}; "
        f"carriers={carriers} rows={rows} last="
        f"{acknowledgements[-1] if acknowledgements else None}")


def stream_held_drag(qmp, udp, lease, sequence, target,
                     generation, samples=12):
    """Drive while held without awaiting a cooperative task-time ack.

    Finder owns a nested tracking loop after mouse-down, so NOW may not run
    again until mouse-up. The UDP notifier and ADB wrapper remain live; the
    host must preserve edge order and deliver up rather than deadlocking on an
    intermediate acknowledgement that the target process cannot produce.
    """
    packet = DP.encode_state(
        *lease, sequence, *target, generation, True)
    for _ in range(samples):
        udp.send(packet)
        time.sleep(0.03)
        carrier(qmp)
    return {"sequence": sequence, "target": target, "samples": samples}


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--qmp", required=True)
    parser.add_argument("--port", required=True, type=int)
    parser.add_argument("--expect-build-prefix", required=True)
    parser.add_argument("--artifacts", required=True)
    args = parser.parse_args()
    args.artifacts = os.path.abspath(args.artifacts)
    os.makedirs(args.artifacts, exist_ok=True)

    qmp = DP.Qmp(args.qmp)
    link = nowwire.GuestLink.await_guest(args.port, timeout=180)
    build = str(link.hello.get("build") or "")
    if not build.startswith(args.expect_build_prefix):
        raise SystemExit(
            f"wrong guest build: expected {args.expect_build_prefix!r}, "
            f"got {build!r}")
    extension = DP.extension_state(link)
    if int(extension.get("capabilities") or 0) & 0x200 == 0:
        raise SystemExit("resident does not advertise Continuity")

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.setblocking(False)
    udp.connect(("127.0.0.1", args.port))
    lease = (0xADB00001, 0xADB00002, 702)
    receipt = {
        "schema": "now-emulator-virtual-adb/v1",
        "guestBuild": build,
        "residentFingerprint": extension.get("buildFingerprint"),
    }
    try:
        before = DP.mouseloc(link)
        origin = (int(before["x"]), int(before["y"]))
        # Use the same known NOW-window interior as the established direct
        # pointer rig. A relative point from the initial cursor can land on a
        # Finder desktop target, whose nested tracking loop starves NOW and
        # turns an input-authority test into a cooperative-pump test.
        target = (280, 220)
        applies_before = int(before["task cursor applies"])
        native_changes_before = int(before["native changes"])
        physical_packets_before = int(before["ADB injection physical"])
        forced_releases_before = int(before["button forced releases"])
        receipt["arm"] = arm(link, 9701, lease)
        receipt["move"] = drive_target(
            qmp, link, udp, lease, 1, target)
        receipt["down"] = drive_target(
            qmp, link, udp, lease, 2, target, generation=1, down=True)
        drag_target = (min(620, target[0] + 43), min(450, target[1] + 31))
        receipt["drag"] = stream_held_drag(
            qmp, udp, lease, 3, drag_target, generation=1)
        receipt["up"] = drive_target(
            qmp, link, udp, lease, 4, drag_target,
            generation=2, down=False, timeout=12.0)
        after = DP.mouseloc(link)
        actual = (int(after["x"]), int(after["y"]))
        if actual != drag_target:
            raise RuntimeError(
                f"guest reached {actual}, expected drag target {drag_target}")
        if int(after["button down"]) != 0 \
                or int(after["button pending up"]) != 0:
            raise RuntimeError("virtual ADB drag left a held button or up debt")
        if int(after["button forced releases"]) != forced_releases_before:
            raise RuntimeError("virtual ADB drag reached a safety release")
        if int(after["task cursor applies"]) != applies_before:
            raise RuntimeError("Cursor Device position path ran during virtual ADB")
        if int(after["ADB injection packets"]) == 0:
            raise RuntimeError("guest reported no substituted ADB packets")
        if int(after["native changes"]) != native_changes_before:
            raise RuntimeError(
                "an injected ADB packet falsely counted as native input")
        receipt["origin"] = origin
        receipt["target"] = target
        receipt["dragTarget"] = drag_target
        receipt["afterInjection"] = after

        # A larger delta is not a carrier. It must pass through and make the
        # resident relinquish authority to the emulated native ADB mouse.
        qmp.cmd("input-send-event", {"events": [
            {"type": "rel", "data": {"axis": "x", "value": 20}},
        ]})
        receipt["takeover"] = DP.next_exit(link, "guest-input", timeout=8)
        receipt["afterTakeover"] = DP.mouseloc(link)
        if (int(receipt["afterTakeover"]["ADB injection physical"])
                <= physical_packets_before):
            raise RuntimeError(
                "native takeover was not attributed to a physical ADB packet")
        receipt["disarm"] = DP.disarm(link, 9702, lease[2])
        receipt["failure"] = None
    except Exception as error:
        receipt["failure"] = f"{type(error).__name__}: {error}"
        try:
            receipt["disarm"] = DP.disarm(link, 9799, lease[2])
        except Exception as cleanup_error:
            receipt["cleanupFailure"] = (
                f"{type(cleanup_error).__name__}: {cleanup_error}")

    qmp.screendump(os.path.join(args.artifacts, "after-virtual-adb.ppm"))
    path = os.path.join(args.artifacts, "virtual-adb.json")
    with open(path, "w") as handle:
        json.dump(receipt, handle, indent=2)
    print(json.dumps(receipt, indent=2))
    udp.close()
    link.close()
    return 1 if receipt.get("failure") else 0


if __name__ == "__main__":
    raise SystemExit(main())
