"""Read and encode the Continuity contract owned by the shared C headers.

Diagnostic tools import this module rather than copying the version, magic,
flags, state values, packet sizes, or ``struct`` layouts.  The C resident and
guest compile ``contract/continuity_udp.h`` directly; this is the one Python
adapter for tools that cannot.
"""

from __future__ import annotations

import re
import struct
from dataclasses import dataclass
from pathlib import Path


def _number(path: Path, name: str) -> int:
    match = re.search(
        rf"^\s*#define\s+{re.escape(name)}\s+"
        r"(0[xX][0-9a-fA-F]+|[0-9]+)[uUlL]*\s*"
        r"(?:/\*.*\*/)?\s*$",
        path.read_text(), re.MULTILINE)
    if not match:
        raise RuntimeError(f"{path}: no numeric {name} definition")
    return int(match.group(1), 0)


def values(repo_root: Path) -> dict[str, int | str]:
    contract = repo_root / "contract"
    major = _number(contract / "resident_version.h",
                    "NOW_RESIDENT_VERSION_MAJOR")
    minor = _number(contract / "resident_version.h",
                    "NOW_RESIDENT_VERSION_MINOR")
    return {
        "continuityWire": _number(contract / "continuity_udp.h",
                                  "NOW_CONTINUITY_VERSION"),
        "continuityTable": _number(contract / "peek_table.h",
                                   "NOW_CONTINUITY_FORMAT_CURRENT"),
        "resident": f"{major}.{minor}",
    }


@dataclass(frozen=True)
class ContinuityContract:
    version: int
    state_magic: int
    state_bytes: int
    flag_inside: int
    flag_primary_down: int
    flag_keepalive: int
    ack_magic: int
    ack_bytes: int
    ack_inactive: int
    ack_armed: int
    ack_active: int
    exit_none: int
    exit_host_left: int
    exit_guest_input: int
    exit_lease_expired: int
    exit_disarmed: int
    state_struct: struct.Struct
    ack_struct: struct.Struct

    def encode_state(self, nonce_hi: int, nonce_lo: int, epoch: int,
                     sequence: int, h: int, v: int, button_generation: int,
                     requested_hz: int, host_stamp: int, flags: int) -> bytes:
        return self.state_struct.pack(
            self.state_magic, self.version, flags, nonce_hi, nonce_lo, epoch,
            sequence, h, v, button_generation, requested_hz, 0, host_stamp)

    def decode_ack(self, raw: bytes) -> dict[str, int]:
        if len(raw) != self.ack_bytes:
            raise ValueError(
                f"ack is {len(raw)} bytes, expected {self.ack_bytes}")
        fields = self.ack_struct.unpack(raw)
        if fields[0] != self.ack_magic or fields[1] != self.version:
            raise ValueError(f"bad Continuity ack header {fields[:2]}")
        return {
            "state": fields[2], "nonceHi": fields[3],
            "nonceLo": fields[4], "epoch": fields[5],
            "positionSequence": fields[6], "buttonGeneration": fields[7],
            "acceptedHz": fields[8], "exitReason": fields[9],
            "arrivalTicks": fields[10], "applyTicks": fields[11],
            "rejectedPackets": fields[12],
        }


def load(repo_root: Path) -> ContinuityContract:
    header = repo_root / "contract/continuity_udp.h"
    number = lambda name: _number(header, name)
    state = struct.Struct(">IHHIIIIhhIHHI")
    ack = struct.Struct(">IHHIIIIIHHIII")
    state_bytes = number("NOW_CONTINUITY_STATE_BYTES")
    ack_bytes = number("NOW_CONTINUITY_ACK_BYTES")
    if state.size != state_bytes or ack.size != ack_bytes:
        raise RuntimeError(
            "Python Continuity packet layouts disagree with "
            f"{header}: state {state.size}/{state_bytes}, "
            f"ack {ack.size}/{ack_bytes}")
    return ContinuityContract(
        version=number("NOW_CONTINUITY_VERSION"),
        state_magic=number("NOW_CONTINUITY_STATE_MAGIC"),
        state_bytes=state_bytes,
        flag_inside=number("NOW_CONTINUITY_FLAG_INSIDE"),
        flag_primary_down=number("NOW_CONTINUITY_FLAG_PRIMARY_DOWN"),
        flag_keepalive=number("NOW_CONTINUITY_FLAG_KEEPALIVE"),
        ack_magic=number("NOW_CONTINUITY_ACK_MAGIC"),
        ack_bytes=ack_bytes,
        ack_inactive=number("NOW_CONTINUITY_ACK_INACTIVE"),
        ack_armed=number("NOW_CONTINUITY_ACK_ARMED"),
        ack_active=number("NOW_CONTINUITY_ACK_ACTIVE"),
        exit_none=number("NOW_CONTINUITY_EXIT_NONE"),
        exit_host_left=number("NOW_CONTINUITY_EXIT_HOST_LEFT"),
        exit_guest_input=number("NOW_CONTINUITY_EXIT_GUEST_INPUT"),
        exit_lease_expired=number("NOW_CONTINUITY_EXIT_LEASE_EXPIRED"),
        exit_disarmed=number("NOW_CONTINUITY_EXIT_DISARMED"),
        state_struct=state, ack_struct=ack)
