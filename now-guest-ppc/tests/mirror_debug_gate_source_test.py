#!/usr/bin/env python3
"""The mirror debug gate covers the firehose and ONLY the firehose.

Two directions, both quiet if they regress. Ungating the diagnostics
re-buries the product's story — a three-minute session on 2026-08-15
cycled 18 Continuity epochs and left the 2000-line ring ~97% mirror
counter dumps, with `tail` (40 lines) able to answer "what happened"
only with counters. Gating the LIFECYCLE lines is the 2026-08-07
silence back again: arm/disarm, selection, grants and every warn/error
must reach the log whether or not somebody remembered to enable
debugging.

Textual, like the host's parity gates: it reads the same dispatch and
guard lines a human reads, and it fails loudly rather than parsing C.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
INTAKE = (ROOT / "now-guest-ppc/src/input/continuity_intake.c").read_text()
SERVICE = (ROOT / "now-guest-ppc/src/input/continuity_service.c").read_text()
CURSOR = (ROOT / "now-guest-ppc/src/input/continuity_cursor.c").read_text()
SELECTION = (
    ROOT / "now-guest-ppc/src/input/continuity_selection.c").read_text()
MIRROR_LOG = (ROOT / "now-guest-ppc/src/mirror/mirror_log.c").read_text()
COMMANDS = (ROOT / "now-guest-ppc/src/commands/commands.c").read_text()


def body(name, source):
    start = source.index(name)
    opening = source.index("{", start)
    depth = 0
    for offset, character in enumerate(source[opening:], opening):
        if character == "{":
            depth += 1
        elif character == "}":
            depth -= 1
            if depth == 0:
                return source[start:offset + 1]
    raise ValueError(f"unterminated function body: {name}")


def gated(source, line_marker, name):
    """The nearest preceding debug-gate test within the same function.

    Coarse on purpose: it asserts a now_mirror_debug_on() call appears
    BEFORE the marker and within 4000 characters, which is enough to
    catch the mutation that matters — deleting the guard entirely."""
    at = source.index(line_marker)
    window = source[max(0, at - 4000):at]
    if "now_mirror_debug_on()" not in window:
        failures.append(
            f"{name}: '{line_marker}' is no longer behind "
            "now_mirror_debug_on() — the diagnostic firehose is "
            "unconditional again and the ring returns to ~97% counters")


failures = []

disarm = body("int now_continuity_disarm(", INTAKE)
take_report = body("int now_continuity_take_report(", INTAKE)

# --- the debug tier is gated -----------------------------------------
gated(disarm, '"tracking epoch=', "disarm counter dump")
gated(take_report, '"native samples=', "report counter block")
gated(take_report, '"button generation=', "report button block")
gated(take_report, '"UDP requested=%u bound=%u"', "report UDP block")
gated(SERVICE, '"idle settle count=', "idle settle trace")
gated(SERVICE, '"synthetic event observed down=', "synthetic event trace")
gated(SERVICE, '"front at down generation=%lu psn=%lu name=%s"',
      "front-at-down success trace")
gated(CURSOR, '"CDM PPC button begin', "CDM button breadcrumb")
gated(CURSOR, '"CDM PPC move begin', "CDM move breadcrumb")

# --- bad news does not need the gate ---------------------------------
# The bypass must be OR-ed onto the gate condition itself, so the check
# demands the literal `now_mirror_debug_on() || <bad news>` join. Two
# earlier spellings of this check each passed the exact mutation they
# name — the identifiers also occur inside the gated bodies — and were
# caught by watching the mutation, 2026-08-15. Only the join is proof.
import re

for pattern, said in (
        (r"now_mirror_debug_on\(\)\s*\|\|\s*out->state\s*==\s*"
         r"\(NowPeekU32\)kNowPeekContinuityStateRefused",
         "a refused report"),
        (r"now_mirror_debug_on\(\)\s*\|\|\s*shared->key_failures != 0"
         r"\s*\|\|\s*shared->key_dropped != 0",
         "a keyboard failure or drop"),
        (r"now_mirror_debug_on\(\)\s*\|\|\s*gAckErrors != 0",
         "an ACK error")):
    if not re.search(pattern, take_report):
        failures.append(
            f"take_report no longer lets bad news past the gate: {said} "
            "is not OR-ed onto its now_mirror_debug_on() condition, so it "
            "logs only when somebody remembered to enable debugging")

# --- the product's story is never gated ------------------------------
for path_name, source in (("continuity_selection.c", SELECTION),
                          ("mirror_log.c", MIRROR_LOG)):
    if "now_mirror_debug_on" in source:
        failures.append(
            f"{path_name} consults the mirror debug gate. Selection, "
            "grants, the writer verdict and arm/disarm outcomes are the "
            "product's story and must log unconditionally")
for marker in ('"disarm epoch=%lu reset requested"',
               '"arm epoch=%lu hz=%lu'):
    at = INTAKE.index(marker)
    window = INTAKE[max(0, at - 600):at]
    if "now_mirror_debug_on()" in window:
        failures.append(
            f"lifecycle line {marker} appears to sit behind the debug "
            "gate; arm/disarm must survive with the gate off")

# --- one mutating implementation, and it logs its own transitions ----
run_mirrorlog = body("static void run_mirrorlog(", COMMANDS)
for marker in ('"debug logging on"', '"debug logging off"'):
    if marker not in run_mirrorlog:
        failures.append(
            "run_mirrorlog no longer logs the transition "
            f"({marker}); the log can no longer name who opened the "
            "firehose, which is the failure mode the no-prefs decision "
            "was made against")
if SELECTION.count("now_mirror_debug_set") != 0 \
        or INTAKE.count("now_mirror_debug_set") != 0 \
        or SERVICE.count("now_mirror_debug_set") != 0 \
        or CURSOR.count("now_mirror_debug_set") != 0:
    failures.append(
        "a continuity source mutates the mirror debug flag; run_mirrorlog "
        "in commands.c is the one implementation behind both faces")

if failures:
    for failure in failures:
        print(f"FAIL: {failure}")
    raise SystemExit(1)
print("mirror_debug_gate_source_test: ok")
