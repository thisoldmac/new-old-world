#!/usr/bin/env python3
"""Pin Continuity v2's task-time/event and interrupt-time/release split."""

import os
from pathlib import Path


ROOT = Path(os.environ.get("NOW_SOURCE_ROOT", Path(__file__).resolve().parents[2]))
RESIDENT = (ROOT / "ext/src/now_ext_continuity.c").read_text()
CURSOR = (ROOT / "ext/src/now_ext_cursor.c").read_text()
PPC = (ROOT / "now-guest-ppc/src/input/continuity_service.c").read_text()
PPC_CURSOR = (ROOT / "now-guest-ppc/src/input/continuity_cursor.c").read_text()
HOST = (ROOT / "now-host/Sources/Host/MirrorContinuityController.swift").read_text()
CONTRACT = (ROOT / "contract/continuity_udp.h").read_text()
EXT_CMAKE = (ROOT / "ext/CMakeLists.txt").read_text()
TRACKING_ASM = (ROOT / "ext/src/now_ext_cursor_tracking.S").read_text()


def body(source: str, start_name: str, end_name: str) -> str:
    start = source.index(start_name)
    end = source.index(end_name, start)
    return source[start:end]


tick = body(RESIDENT, "void now_ext_continuity_tick(TMTaskPtr task)\n{",
            "int now_ext_continuity_boot(")
release = body(RESIDENT, "static void release_button_lowmem(",
               "static void request_button(")
request = body(RESIDENT, "static void request_button(",
               "static void release_button(")
release_transition = body(RESIDENT, "static void release_button(",
                          "static int process_event_result(")
result = body(RESIDENT, "static int process_event_result(",
              "static void force_reset(")
service = body(RESIDENT, "void now_ext_continuity_service(",
               "void now_ext_continuity_tick(")
reveal = body(CURSOR, "void now_ext_cursor_reveal_continuity(",
              "void now_ext_cursor_remember_continuity_tracking_point(")
tracking_begin = body(
    CURSOR, "void now_ext_cursor_begin_continuity_tracking_visuals(",
    "void now_ext_cursor_end_continuity_tracking(")
tracking_complete = body(
    CURSOR, "void now_ext_cursor_complete_continuity_tracking(",
    "int now_ext_cursor_enable_continuity_tracking(")
tracking_gne = body(CURSOR, "void now_ext_cursor_gne(NowPeekTable *table)\n{",
                    "int now_ext_cursor_boot(")
host_buttons = body(HOST, "func primaryDown", "func cancel")
failures = []


def check(ok: bool, message: str) -> None:
    if not ok:
        failures.append(message)


check("#define NOW_CONTINUITY_VERSION 2u" in CONTRACT,
      "the direct-pointer wire is not versioned independently from v0")
check("kNowPeekContinuityFormatV7" in RESIDENT,
      "the resident no longer requires the V6 ADB observer table tail")
check("now_ext_continuity_tm.S" in EXT_CMAKE,
      "the held-button release vehicle is not linked")
check("now_continuity_cursor_button(" in PPC,
      "the PPC task-time half no longer owns button transitions")
check("now_cdm_button_down(gDevice)" in PPC_CURSOR
      and "now_cdm_button_up(gDevice)" in PPC_CURSOR,
      "primary transitions no longer use the synthetic Cursor Device")
check("PPostEvent" not in RESIDENT and "PostEvent(" not in RESIDENT,
      "the 68K resident again calls Event Manager")
for token in ("PostEvent", "PPostEvent", "HideCursor", "ShowCursor",
              "now_cdm_", "GetFrontProcess", "SetFrontProcess", "NewPtr",
              "DisposePtr", "now_log", "LMSetMouseTemp",
              "LMSetRawMouseLocation", "now_ext_cursor_place"):
    check(token not in tick,
          f"the held-button timer again reaches unsafe work: {token}")
check("LMSetMouseLocation(pt)" in tick,
      "the timer no longer advances tracking-loop MouseLocation")
check("now_ext_cursor_remember_continuity_tracking_point(h, v)" in tick,
      "tracking-loop points are no longer excluded from native takeover")
check("now_ext_cursor_reassert_continuity_tracking()" in tick
      and "kNowPeekContinuityTrackingPinHeldPoint" in tick,
      "the optional held-point pin no longer runs from the bounded timer")
check("position_seq, cell->request_position_seq" in tick
      and "cell->applied_position_seq = position_seq" not in tick,
      "the timer again claims a manager apply or repeats one tracking point")
check("LMSetMouseButtonState(0x80)" in release
      and "LMSetMouseButtonState(0x00)" not in RESIDENT,
      "the resident's only button write is no longer unconditional up")
check("event_request_generation = 0" in request
      and request.index("event_request_generation = 0")
          < request.index("event_request_down ="),
      "button direction can again publish under the preceding generation")
check("applied_button_generation = release_generation"
      not in release_transition,
      "the resident again ACKs up before the PPC manager transition settles")
check("applied_button_generation = generation" in result
      and "event_result_err == noErr" in result,
      "successful PPC manager-up no longer owns the release ACK")
check("now_ext_cursor_complete_continuity_tracking();" in service,
      "normal release no longer settles the final point after manager-up")
check("now_ext_cursor_complete_continuity_tracking();" in service
      and service.index("now_ext_cursor_complete_continuity_tracking();")
          > service.index("cell->apply_result_seq"),
      "normal release can clear its source before the final PPC move commits")
check("gReleaseSettleStarted" in tick
      and "now_ext_cursor_end_continuity_tracking();" in tick,
      "a starved normal release can retain its tracking source forever")
check("kNowPeekContinuityExitLeaseExpired" in tick
      and "kNowPeekContinuityExitGuestInput" in tick
      and "kNowPeekContinuityExitHostLeft" in tick,
      "the timer no longer covers every forced-release boundary")
check("now_continuity_button_action" in service,
      "the resident no longer consumes the v2 primary transition")
check("now_ext_cursor_reveal_continuity();" in service,
      "task-time synthetic movement no longer reveals an obscured cursor")
check("now_ext_cursor_reveal_continuity" not in tick,
      "the interrupt timer again reaches cursor visibility/QuickDraw work")
for token in ("HideCursor", "ShowCursor", "LMSetRawMouseLocation",
              "LMSetMouseTemp", "now_cdm_"):
    pin = body(CURSOR, "int now_ext_cursor_reassert_continuity_tracking(",
               "int now_ext_cursor_answer_continuity_getmouse(")
    check(token not in pin,
          f"the optional held-point pin reaches unsafe work: {token}")
check("jsr now_ext_cursor_answer_continuity_getmouse" in TRACKING_ASM
      and "addq.l #4,%sp" in TRACKING_ASM,
      "Virtual GetMouse no longer owns its Pascal argument cleanup")
check("*gCrsrObscure = 0" in reveal
      and "HideCursor();" in reveal and "ShowCursor();" in reveal,
      "Continuity no longer reproduces the native mouse visibility wake")
check("HideCursor();" in tracking_begin
      and "gNowCursorTrackingCursorHidden = 1" in tracking_begin,
      "the optional drag-visibility experiment no longer hides exactly in task time")
check("now_ext_cursor_end_continuity_tracking();" in tracking_complete
      and "ShowCursor();" in tracking_complete,
      "normal release no longer balances the optional hidden cursor")
check("!gNowCursorTrackingSourceActive" in tracking_gne
      and "ShowCursor();" in tracking_gne,
      "the task-time watchdog recovery no longer balances a hidden cursor")
check("applied_button_generation" in service,
      "the resident no longer acknowledges button transitions")
check("guard phase == .active" in host_buttons,
      "the host bypasses Mirror before the raw lane is active")
check("flags.insert(.primaryDown)" in HOST
      and "buttonGeneration: buttonGeneration" in HOST,
      "the host no longer sends primary state plus its generation")
check("if pressAcknowledged { sendPrimaryRelease() }" in host_buttons,
      "the host can send release before the press acknowledgement")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)

print("continuity v2 event/interrupt safety source guard: ok")
