#!/usr/bin/env python3
"""Pin the v0 movement-only boundary.

Clicks are v0.5a. The v0 resident must never touch global button state or the
Event Manager, even when a version-1 packet carries the reserved button fields.
"""

import os
from pathlib import Path


ROOT = Path(os.environ.get("NOW_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
SOURCE = (ROOT / "ext/src/now_ext_continuity.c").read_text()
HOST = (ROOT / "now-host/Sources/Host/MirrorContinuityController.swift").read_text()
CONTRACT = (ROOT / "contract/continuity_udp.h").read_text()


def body(start_name: str, end_name: str) -> str:
    start = SOURCE.index(start_name)
    end = SOURCE.index(end_name, start)
    return SOURCE[start:end]


service = body("void now_ext_continuity_service(",
               "int now_ext_continuity_boot(")
failures = []


def check(ok: bool, message: str) -> None:
    if not ok:
        failures.append(message)


for token in ("PPostEvent", "LMSetMouseButtonState", "mouseDown", "mouseUp",
              "gPendingMouse", "gPostedMouse"):
    check(token not in SOURCE,
          f"Continuity v0 again reaches button/Event Manager state: {token}")
check("kNowPeekContinuityPrimaryDown" not in service,
      "the v0 service again consumes the reserved primary-down flag")
check("button_generation =" not in service,
      "the v0 service again consumes reserved button generations")
check("cell->applied_button_generation = 0" in SOURCE,
      "v0 no longer publishes its reserved button generation as zero")
check("return false" in HOST[HOST.index("func primaryDown"):
                             HOST.index("func cancel")],
      "the host again bypasses Mirror clicks before v0.5a")
check("buttonGeneration: 0" in HOST,
      "the v0 host no longer writes zero to the reserved button slot")
check("Reserved on the version-1 wire for v0.5a" in CONTRACT,
      "the fixed wire no longer explains why its button slots are reserved")
check("now_ext_cursor_physical_input_seq()" in service,
      "the service no longer samples native input before host placement")
for token in ("now_ext_continuity_tick", "now_ext_continuity_gne",
              "PrimeTime", "InsTime"):
    check(token not in SOURCE,
          f"v0 again depends on the failed resident scheduling path: {token}")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)

print("continuity v0 movement-only source guard: ok")
