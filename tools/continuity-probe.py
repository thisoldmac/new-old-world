#!/usr/bin/env python3
"""Exercise one real guest's Continuity control and UDP lanes.

The guest dials this instrument over NOW's ordinary framed TCP wire. The
instrument grants one short movement-only V2 epoch, sends one fixed-size UDP
state to the port the guest reports (never the requested port by assumption),
requires a matching acknowledgement, and disarms before closing.

Under ``scripts/spin-up-ppc`` the same host port is also a QEMU UDP hostfwd,
so TCP listens on that port while UDP sends to it from an ephemeral source
port. On metal, pass the guest's observed IP with ``--udp-host``.
"""

import argparse
import json
import os
import select
import socket
import struct
import sys
import time

sys.path.insert(0, os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "contract"))
from wire_limits import (CHANNEL_CONTROL as CONTROL,  # noqa: E402
                         FLAG_END as END,
                         WIRE_CONTRACT_REVISION as CONTRACT)


STATE_MAGIC = 0x4E574331
ACK_MAGIC = 0x4E574131
CONTINUITY_VERSION = 2
STATE_INSIDE = 0x0001
ACK_BYTES = 44


def frame(payload):
    return struct.pack(">BBHI", CONTROL, END, 0, len(payload)) + payload


def encode_state(nonce_hi, nonce_lo, epoch, sequence, h=100, v=100,
                 requested_hz=15):
    return struct.pack(
        ">IHHIIIIhhIHHI", STATE_MAGIC, CONTINUITY_VERSION, STATE_INSIDE,
        nonce_hi, nonce_lo, epoch, sequence, h, v, 0, requested_hz, 0,
        int(time.monotonic() * 60) & 0xFFFFFFFF)


def decode_ack(payload):
    if len(payload) != ACK_BYTES:
        raise ValueError(f"ack is {len(payload)} bytes, expected {ACK_BYTES}")
    values = struct.unpack(">IHHIIIIIHHIII", payload)
    if values[0] != ACK_MAGIC or values[1] != CONTINUITY_VERSION:
        raise ValueError("ack magic or version does not match Continuity v2")
    return {
        "state": values[2],
        "nonceHi": values[3],
        "nonceLo": values[4],
        "epoch": values[5],
        "positionSequence": values[6],
        "buttonGeneration": values[7],
        "acceptedHz": values[8],
        "exitReason": values[9],
        "arrivalTicks": values[10],
        "applyTicks": values[11],
        "rejectedPackets": values[12],
    }


class FramedGuest:
    def __init__(self, sock):
        self.sock = sock
        self.buffer = b""

    def send(self, obj):
        self.sock.sendall(frame(json.dumps(obj).encode()))

    def receive(self):
        while True:
            while len(self.buffer) >= 8:
                _, _, _, length = struct.unpack(">BBHI", self.buffer[:8])
                if len(self.buffer) < 8 + length:
                    break
                payload = self.buffer[8:8 + length]
                self.buffer = self.buffer[8 + length:]
                return json.loads(payload.decode("utf-8", "replace"))
            chunk = self.sock.recv(65536)
            if not chunk:
                raise RuntimeError("guest closed the control connection")
            self.buffer += chunk


def receive_control(guest, wanted_id, deadline):
    while time.monotonic() < deadline:
        ready, _, _ = select.select([guest.sock], [], [],
                                    max(0, deadline - time.monotonic()))
        if not ready:
            break
        message = guest.receive()
        if message.get("type") == "ping":
            guest.send({"type": "pong", "id": message.get("id", 0)})
            continue
        if message.get("id") == wanted_id:
            return message
    raise TimeoutError(f"no correlated control report for id {wanted_id}")


def receive_ack(guest, udp, expected, deadline):
    while time.monotonic() < deadline:
        timeout = max(0, deadline - time.monotonic())
        ready, _, _ = select.select([guest.sock, udp], [], [], timeout)
        if not ready:
            break
        if udp in ready:
            payload, peer = udp.recvfrom(256)
            ack = decode_ack(payload)
            for key in ("nonceHi", "nonceLo", "epoch"):
                if ack[key] != expected[key]:
                    raise ValueError(f"ack {key} does not match the lease")
            return ack, peer
        message = guest.receive()
        if message.get("type") == "ping":
            guest.send({"type": "pong", "id": message.get("id", 0)})
    raise TimeoutError("no matching UDP acknowledgement")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, required=True,
                        help="TCP listen port and UDP destination/forward")
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--udp-host", default=None,
                        help="guest IP; defaults to the accepted TCP peer")
    parser.add_argument("--wait", type=float, default=180)
    parser.add_argument("--timeout", type=float, default=10)
    args = parser.parse_args()

    server = socket.socket()
    server.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server.bind((args.host, args.port))
    server.listen(1)
    server.settimeout(args.wait)
    print(f"continuity probe listening on {args.host}:{args.port}", flush=True)
    control, tcp_peer = server.accept()
    control.settimeout(args.timeout)
    guest = FramedGuest(control)
    hello = guest.receive()
    guest.send({"type": "hello", "contract": CONTRACT, "side": "host",
                "version": "0", "name": "continuity-probe", "chunk": 4096})

    nonce_hi = 0x13579BDF
    nonce_lo = 0x2468ACE0
    epoch = 1
    arm_id = 7001
    disarm_id = 7002
    lease = {"nonceHi": nonce_hi, "nonceLo": nonce_lo, "epoch": epoch}
    guest.send({"type": "continuity.arm", "version": 2, "id": arm_id,
                **lease, "requestedHz": 15, "leaseTicks": 120})
    arm = receive_control(guest, arm_id, time.monotonic() + args.timeout)
    if arm.get("state") != "armed" or not arm.get("udpPort"):
        raise RuntimeError("guest refused Continuity: " + json.dumps(arm))

    udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    udp.bind((args.host, 0))
    destination = (args.udp_host or tcp_peer[0], int(arm["udpPort"]))
    udp.sendto(encode_state(nonce_hi, nonce_lo, epoch, 1), destination)
    ack, udp_peer = receive_ack(
        guest, udp, lease, time.monotonic() + args.timeout)
    if ack["positionSequence"] != 1 or ack["rejectedPackets"] != 0:
        raise RuntimeError("guest did not accept the probe state: "
                           + json.dumps(ack))

    guest.send({"type": "continuity.disarm", "version": 2,
                "id": disarm_id, "epoch": epoch, "reason": "disabled"})
    disarm = receive_control(guest, disarm_id,
                             time.monotonic() + args.timeout)
    guest.send({"type": "bye"})
    result = {
        "guest": hello,
        "arm": arm,
        "udpDestination": f"{destination[0]}:{destination[1]}",
        "udpReplyFrom": f"{udp_peer[0]}:{udp_peer[1]}",
        "ack": ack,
        "disarm": disarm,
    }
    print(json.dumps(result, indent=2, sort_keys=True))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as error:
        print(f"continuity probe failed: {error}", file=sys.stderr)
        sys.exit(1)
