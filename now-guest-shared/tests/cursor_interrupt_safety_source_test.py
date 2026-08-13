#!/usr/bin/env python3
"""Pin Continuity V4's Apple-corrected PowerPC Cursor Device boundary.

The sixth PowerBook wedge falsified the generic PPC -> resident 68K -> AADB
route. Universal Interfaces explicitly requires CursorDevicesGlue for PowerPC
because the original manager transition was wrong. The supplied glue cannot be
strongly linked into this Carbon CFM app, so NOW reproduces its exact corrected
trap transition for the seven calls it uses. P9 may ask and commit in the
resident, but only the PPC application's ordinary pump may own or call the
synthetic device through that bounded adapter.
"""

import os
from pathlib import Path


ROOT = Path(os.environ.get("NOW_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
CURSOR = (ROOT / "ext/src/now_ext_cursor.c").read_text()
CONTINUITY = (ROOT / "ext/src/now_ext_continuity.c").read_text()
PPC_CURSOR = (ROOT / "now-guest-ppc/src/input/continuity_cursor.c").read_text()
PPC_TRANSITION = (ROOT / "now-guest-ppc/src/input/continuity_cdm_transition.c").read_text()
SERVICE = (ROOT / "now-guest-ppc/src/input/continuity_service.c").read_text()
PPC_CMAKE = (ROOT / "now-guest-ppc/CMakeLists.txt").read_text()
EXT_CMAKE = (ROOT / "ext/CMakeLists.txt").read_text()
CORE = (ROOT / "ext/src/now_ext.c").read_text()
INTAKE = (ROOT / "now-guest-ppc/src/input/continuity_intake.c").read_text()


def function_body(source: str, signature: str, next_signature: str) -> str:
    start = source.index(signature)
    end = source.index(next_signature, start)
    return source[start:end]


resident_service = function_body(
    CONTINUITY, "void now_ext_continuity_service(",
    "void now_ext_continuity_tick(")
reveal = function_body(
    CURSOR, "void now_ext_cursor_reveal_continuity(",
    "void now_ext_cursor_remember_continuity_tracking_point(")
ppc_move = function_body(
    PPC_CURSOR, "long now_continuity_cursor_move(",
    "void now_continuity_cursor_shutdown(")
ppc_button = function_body(
    PPC_CURSOR, "long now_continuity_cursor_button(",
    "long now_continuity_cursor_move(")
ppc_ready = function_body(
    PPC_CURSOR, "int now_continuity_cursor_ready(",
    "void now_continuity_cursor_begin_epoch(")
notifier_accept = function_body(
    INTAKE, "static void accept_datagram(",
    "static void drain_endpoint(")
failures = []


def check(ok: bool, message: str) -> None:
    if not ok:
        failures.append(message)


for token in ("now_cdm_", "CursorDeviceMoveTo(", "CursorDeviceNewDevice(",
              "CursorDeviceSetButtons(", "CursorDeviceUnitsPerInch(",
              "CursorDeviceDisposeDevice(", "LMSet", "PPostEvent",
              "HideCursor", "ShowCursor", "PrimeTime", "InsTime"):
    check(token not in resident_service,
          f"resident Continuity service again reaches forbidden route: {token}")
check("request_position_seq = position_seq" in resident_service,
      "resident no longer publishes a bounded placement request")
check("apply_result_seq == cell->request_position_seq" in resident_service,
      "resident no longer commits only the exact PPC placement result")
check("now_ext_cursor_remember_continuity_point" in resident_service,
      "successful PPC placements are no longer excluded from native takeover")
check("gServiceActive" in resident_service
      and "service_reentries" in resident_service,
      "resident service lost its non-reentrant guard and counter")
check("trace_event" in resident_service,
      "resident service lost its allocation-free flight recorder")
check("now_ext_cursor_reveal_continuity();" in resident_service,
      "successful task-time movement no longer wakes an obscured cursor")
check("HideCursor();" in reveal and "ShowCursor();" in reveal,
      "the task-time visibility wake no longer redraws through QuickDraw")
check("*gCrsrObscure = 0;" in reveal
      and reveal.index("*gCrsrObscure = 0;") < reveal.index("HideCursor();"),
      "the task-time visibility wake no longer clears obscured state first")
check("return;" not in reveal,
      "a nominally clear CrsrObscure can still suppress the sprite redraw")

check("now_cdm_move_to(gDevice" in ppc_move,
      "PPC task-time cursor path no longer uses the corrected transition")
for token in ("LMSet", "PPostEvent", "HideCursor", "ShowCursor",
              "CallUniversalProc", "0xAADB"):
    check(token not in ppc_move,
          f"PPC cursor move again carries a substitute route: {token}")
check("now_cdm_new_device(&device)" in ppc_ready,
      "PPC application no longer owns its synthetic Cursor Device")
check("now_cdm_set_buttons" in ppc_ready
      and "now_cdm_units_per_inch" in ppc_ready
      and "now_cdm_dispose_device" in PPC_CURSOR,
      "PPC Cursor Device setup/cleanup is no longer failure-atomic")
check(ppc_move.count("now_log_memory") >= 2
      and "move begin" in ppc_move and "move return" in ppc_move,
      "PPC cursor move lost its allocation-free pre/post flight recorder")
check("now_log_flush();" not in ppc_move,
      "PPC cursor move again flushes the disk in the live input path")
check("now_cdm_button_down(gDevice)" in ppc_button
      and "now_cdm_button_up(gDevice)" in ppc_button,
      "PPC primary transitions no longer use the corrected synthetic device")
check(ppc_button.count("now_log_memory") >= 2
      and "button begin" in ppc_button and "button return" in ppc_button,
      "PPC cursor button lost its allocation-free pre/post flight recorder")
check("now_log_flush();" not in ppc_button,
      "PPC cursor button again flushes the disk in the live input path")

for token in ("libCursorDevicesGlue.a", "libInterfaceLib.a"):
    check(token not in PPC_CMAKE,
          f"Carbon guest again has a load-time non-Carbon cursor import: {token}")
check("src/input/continuity_cdm_transition.c" in PPC_CMAKE,
      "the bounded PPC Cursor Device transition is not in the guest build")
check("src/input/continuity_cursor.c" in PPC_CMAKE,
      "the PPC-owned Cursor Device module is not in the guest build")

for token in ('"CallUniversalProc"', '"NGetTrapAddress"', "0xAADB",
              "kNowCDMProcInfoOnePointer = 0x03E8",
              "kNowCDMProcInfoPointerShort = 0x0BE8",
              "kNowCDMProcInfoPointerLong = 0x0FE8",
              "kNowCDMProcInfoPointerLongLong = 0x3FE8",
              "kNowCDMMoveTo = 1", "kNowCDMButtonDown = 4",
              "kNowCDMButtonUp = 5", "kNowCDMSetButtons = 7",
              "kNowCDMUnitsPerInch = 10", "kNowCDMNewDevice = 12",
              "kNowCDMDisposeDevice = 13"):
    check(token in PPC_TRANSITION,
          f"Apple CursorDevicesGlue transition drifted: missing {token}")
check("GetSharedLibrary" in PPC_TRANSITION and "FindSymbol" in PPC_TRANSITION,
      "cursor transition again requires a strong InterfaceLib import")
check("gGetTrap" in PPC_TRANSITION and "gCallUPP(gDispatch" in PPC_TRANSITION,
      "cursor transition no longer enters the dispatch trap through Apple's route")

check("NowPeekContinuityCell *shared = gNotifierCell" in notifier_accept,
      "OT notifier no longer uses the task-time cached resident cell")
for token in ("cell()", "now_peek_table", "now_log", "GetCurrentProcess",
              "GetProcessInformation", "FlushVol", "NewPtr", "malloc"):
    check(token not in notifier_accept,
          f"OT notifier again reaches task-time/allocating work: {token}")
check('close_udp("application shutdown")' in INTAKE,
      "application shutdown no longer revokes and closes the UDP notifier")

check("now_ext_continuity_tm.S" in EXT_CMAKE,
      "the direct-pointer release trampoline is not linked")
check("gOwnedDeviceHistory" in CURSOR
      and "gOwnedTrackingHistory" in CURSOR
      and "owned_history_contains" in CURSOR,
      "task-time and timer-owned point history again share an unsafe writer")
check("now_ext_continuity_gne" not in CORE,
      "the global jGNE path again services Continuity")
check("kNowPeekContinuityFormatV8" in CONTINUITY,
      "the resident no longer advertises the direct-pointer contract")
check("now_continuity_cursor_move" in SERVICE
      and "now_continuity_cursor_button" in SERVICE
      and "apply_result_seq = request_seq" in SERVICE
      and "invoke_resident(cell)" in SERVICE,
      "the PPC request/call/result/commit handshake is incomplete")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)

print("cursor PowerPC glue source guard: ok")
