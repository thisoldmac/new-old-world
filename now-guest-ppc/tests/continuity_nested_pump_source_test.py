#!/usr/bin/env python3
"""Pin that a nested wire pump still pumps the cursor plane.

The Continuity position pump is reachable from ``conn_service`` alone, so it
inherited the wire's reentrancy guard.  While this application serves a
request, ``now_wire_pump`` bounces -- and every nested Toolbox loop reached
from that request pumped nothing, so the pointer stopped for the whole serve.

Measured 2026-08-13 (guest log "223323", epoch 12): position applies arrived
48-72 ticks apart, once per second, with a clean 1-tick cadence in between.
That shape is a loop that is not running, not a loop running slowly, and it
lines up with the host's Mirror cycle, which asks for a scene every 0.75 s of
guest-idle time and deliberately does not stand down while Continuity is
armed (the anchor lease renews on ``scene.request``).

Two things are pinned, because closing one without the other leaves the
stall:

  1. ``now_wire_pump``'s bounce calls ``now_continuity_pump`` before it
     returns.  The cursor plane has its own re-entry guard and touches no
     wire state, so the guard has no claim on it.
  2. ``now_peek_settle``'s yield loop pumps.  It is a nested loop by pump.h's
     definition and it is entered for up to ``kNowSceneArmSettleTicks`` at
     the head of every scene walk -- half a second of pure waiting on the one
     path the host polls while a person is moving the pointer.

There is no host-native test for either: both live in Carbon translation
units, and the behaviour is the ORDER of two calls rather than a value.
"""

import re
from pathlib import Path


def uncommented(text: str) -> str:
    """Source with block comments blanked, newlines kept.

    Written after this guard passed the very mutation it was written for.
    Deleting the call from the bounce left the comment above it - which names
    ``now_continuity_pump`` in a sentence explaining why it is there - and the
    substring search was satisfied by the explanation instead of the code.
    Line structure is preserved so offsets still compare.
    """

    return re.sub(
        r"/\*.*?\*/",
        lambda m: re.sub(r"[^\n]", " ", m.group(0)),
        text,
        flags=re.S,
    )


SRC = Path(__file__).resolve().parents[1] / "src"
WIRE = uncommented((SRC / "core" / "wire.c").read_text())
PEEK = uncommented((SRC / "peek" / "peek.c").read_text())
INTAKE_H = uncommented((SRC / "input" / "continuity_intake.h").read_text())
INTAKE_C = uncommented((SRC / "input" / "continuity_intake.c").read_text())

PUMP = "now_continuity_pump"


def function_body(text: str, signature: str, where: str) -> str:
    try:
        start = text.index(signature)
    except ValueError:
        raise SystemExit(f"{where}: no function {signature!r}")
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1 : index]
    raise SystemExit(f"{where}: unterminated function {signature!r}")


# --- the seam exists and is declared -----------------------------------
if f"void {PUMP}(void);" not in INTAKE_H:
    raise SystemExit(
        f"continuity_intake.h does not declare {PUMP}; the nested waits have "
        "no way to keep the cursor alive without re-entering the wire"
    )

pump_body = function_body(INTAKE_C, f"void {PUMP}(void)", "continuity_intake.c")
if "now_continuity_service_invoke" not in pump_body:
    raise SystemExit(
        f"{PUMP} does not run the apply handshake, so calling it does not "
        "move the pointer"
    )
if "now_peek_claim" not in pump_body:
    raise SystemExit(
        f"{PUMP} does not renew the owner lease; a stall longer than the "
        "lease would expire the plane it is pumping"
    )
# It must not reach for the wire: that is the hazard it exists to route around.
for forbidden in ("send_control", "conn_service", "try_send_ack"):
    if forbidden in pump_body:
        raise SystemExit(
            f"{PUMP} calls {forbidden}: this seam runs while the wire's state "
            "machine is mid-request and may not touch it"
        )

# --- 1. the bounce pumps ------------------------------------------------
wire_pump = function_body(WIRE, "void now_wire_pump(void)", "wire.c")
try:
    guard = wire_pump.index("if (pumping)")
except ValueError:
    raise SystemExit("wire.c: now_wire_pump no longer guards reentrancy")
bounce_return = wire_pump.index("return;", guard)
if PUMP not in wire_pump[guard:bounce_return]:
    raise SystemExit(
        "now_wire_pump returns from its reentrancy bounce without calling "
        f"{PUMP}. Every nested loop entered while serving a request then "
        "pumps nothing, and the pointer stops for the whole serve - the "
        "48-72 tick stalls measured on 2026-08-13."
    )

# --- 2. the settle loop pumps ------------------------------------------
settle = function_body(
    PEEK, "int now_peek_settle(unsigned long caps, unsigned long max_ticks)",
    "peek.c",
)
yields = settle.count("WaitNextEvent")
if yields != 1:
    raise SystemExit(
        f"now_peek_settle has {yields} yields; this guard assumes one and "
        "must be taught the others rather than silently covering none"
    )
yield_at = settle.index("WaitNextEvent")
pumps_at = settle.find("now_wire_pump")
if pumps_at < 0 or pumps_at < yield_at:
    raise SystemExit(
        "now_peek_settle yields the processor without pumping after it. "
        "pump.h's rule has no exception for loops that only wait, and "
        "serve_scene enters this one for up to kNowSceneArmSettleTicks "
        "before every walk the host asks for."
    )

print("ok")
