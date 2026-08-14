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
WIRE = (ROOT / "now-guest-ppc/src/core/wire.c").read_text()
EXT_CORE = (ROOT / "ext/src/now_ext.c").read_text()
INTAKE = (ROOT / "now-guest-ppc/src/input/continuity_intake.c").read_text()
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
edge = body(RESIDENT, "static void apply_button_edge(",
            "void now_ext_continuity_service(")
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


check("#define NOW_CONTINUITY_VERSION 4u" in CONTRACT,
      "the direct-pointer wire is not versioned independently from v0")
check("NOW_CONTINUITY_FORMAT_CURRENT" in RESIDENT,
      "the resident no longer requires the shared current table format")
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
check("now_continuity_button_action" in edge
      and "apply_button_edge(cell, previous_button_generation" in service
      and "apply_button_edge(cell, button_generation" in service,
      "the resident no longer consumes v4 button history in order")
check("gDeferredPressGeneration" in edge
      and "button_edge_deferrals++" in edge
      and "button_edge_overflows++" in edge,
      "the resident no longer bounds a press deferred behind manager-up")
check("gDeferredPressGeneration" in result
      and "request_button(cell, deferred, 1)" in result,
      "a settled manager-up no longer releases the deferred second press")
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
check("applied_button_generation" in result,
      "the resident no longer acknowledges button transitions")
check("guard phase == .active" in host_buttons,
      "the host bypasses Mirror before the raw lane is active")
check("flags.insert(.primaryDown)" in HOST
      and "buttonGeneration: buttonGeneration" in HOST,
      "the host no longer sends primary state plus its generation")
# The host streams edges and does not classify clicks. The classification
# machinery (a buffered cycle, an AppKit clickCount fast path, release gated
# on the press acknowledgement) serialized cycles against guest scheduling,
# and a starved target turned that into piled-up drags (2026-08-13 185037).
# Correct ordering is the v4 previous/current pair plus the resident's
# two-slot interrupt release, not host-side pacing.
check("releasePending = true\n        /*" in host_buttons
      and "sendPrimaryRelease()\n        return true" in host_buttons,
      "the host again gates the release on the press acknowledgement")
check("bufferedButtonCycle" not in HOST
      and "capturingBufferedCycle" not in HOST
      and "clickCount >= 2" not in HOST,
      "the host again classifies clicks instead of streaming edges")

# Wide DoubleTime: the guest cannot recognize a double click when cooperative
# scheduling stretches the manager-down interval past GetDblTime (measured
# 40-45 ticks against a 32-tick DoubleTime, 2026-08-13 174816 run). While an
# epoch runs with the host option set, the resident widens the low-memory
# window and restores the saved value on EVERY exit, forced ones included -
# a stale-wide DoubleTime is a behavior change that outlives its epoch.
start_epoch = body(RESIDENT, "static void start_epoch_locked(",
                   "static void apply_button_edge(")
finish = body(RESIDENT, "static void finish_locked(",
              "static void start_epoch_locked(")
check("kNowPeekContinuityTrackingWideDoubleTime" in start_epoch
      and "LMGetDoubleTime()" in start_epoch
      and "LMSetDoubleTime" in start_epoch
      and start_epoch.index("LMGetDoubleTime()")
          < start_epoch.index("LMSetDoubleTime(")
      and start_epoch.index("kNowPeekContinuityTrackingWideDoubleTime")
          < start_epoch.index("LMSetDoubleTime("),
      "arming no longer saves-then-widens DoubleTime under the host option")
check("restore_double_time();" in finish,
      "a normal exit no longer restores the saved DoubleTime")
check("restore_double_time();" in release_transition,
      "a forced release no longer restores the saved DoubleTime")
check('"wideDoubleTime"' in WIRE
      and "kNowPeekContinuityTrackingWideDoubleTime" in WIRE,
      "the wire arm no longer maps wideDoubleTime onto its option bit")

# A slow button-down acknowledgement is a starved cooperative guest, not a
# dead one: the 1-second epoch teardown turned every starved double-click
# into a full ownership bounce (three times in the 174816 run). The timeout
# now abandons the CYCLE - forcing the wire button up inside the epoch so no
# logical hold leaks - and never tears down or reconnects the epoch itself.
timeout_body = body(HOST, "private func scheduleButtonAckTimeout",
                    "private func rearmAfterConfigurationChange")
abandon = body(HOST, "private func abandonPrimaryCycle",
               "private func scheduleButtonAckTimeout")
check("3_000_000_000" in timeout_body,
      "the down acknowledgement bound no longer covers measured starvation")
check("abandonPrimaryCycle(" in timeout_body
      and timeout_body.index("abandonPrimaryCycle(")
          < timeout_body.index("relinquish("),
      "a slow down acknowledgement again ends the whole epoch")
check("advanceButton(to: false)" in abandon
      and "sendState(inside: true" in abandon,
      "an abandoned cycle no longer forces the wire button up in-epoch")
check("relinquish(" not in abandon and "scheduleReconnect(" not in abandon,
      "abandoning a cycle again tears down or reconnects the epoch")

# The interrupt-time release must consider BOTH v4 edge slots. With only the
# current edge visible, spam clicking hides the release in `previous` behind
# the drag its own press started (302-tick starvation, epoch 11, 2026-08-13
# 185037) and the machine drag-locks until physical input.
check("now_continuity_release_due(" in tick
      and "previous_button_generation, previous_button_flags" in tick
      and "button_generation, flags" in tick,
      "the timer release no longer reads both edge slots")

# The manager button ledger must never outlive its epoch asserting a hold.
# The Cursor Device record is upstream of low memory: an unbalanced manager
# down kept a reconnected guest dragging a phantom until physical trackpad
# input rewrote it (2026-08-13 185037). The ledger is settled at every task
# time boundary a dead epoch can reach: the next arm, the service pump when
# the epoch is not active, and shutdown.
check("gLedgerDown = down ? 1 : 0" in PPC_CURSOR,
      "the manager ledger no longer records successful button transitions")
cursor_epoch = body(PPC_CURSOR, "void now_continuity_cursor_begin_epoch(",
                    "long now_continuity_cursor_ensure_released(")
cursor_shutdown = PPC_CURSOR[
    PPC_CURSOR.index("void now_continuity_cursor_shutdown("):]
check("now_continuity_cursor_ensure_released(\"arm\")" in cursor_epoch,
      "a new arm no longer settles the previous epoch's manager hold")
check("now_continuity_cursor_ensure_released(\"shutdown\")"
      in cursor_shutdown,
      "shutdown no longer settles an unbalanced manager hold")
invoke_head = PPC[PPC.index("int now_continuity_service_invoke("):]
invoke_head = invoke_head[:invoke_head.index("for (round = 0;")]
check("now_continuity_cursor_ensure_released(\"inactive\")" in invoke_head
      and "kNowPeekContinuityStateActive" in invoke_head,
      "a dead epoch's pump no longer settles the manager ledger")

# The idle-settle spike may run only from task-time jGNE passes, only when
# the host selected it, never during a held gesture (the hooks own those
# frames), and only when the application is provably behind the wire.
idle_settle = body(CURSOR, "static void settle_continuity_idle_cursor(",
                   "static void record_continuity_tracking_conflict(")
check("settle_continuity_idle_cursor();" in tracking_gne,
      "the jGNE pass no longer runs the idle settle spike")
check("!gNowCursorSettleIdleCursor || gNowCursorTrackingSourceActive"
      in idle_settle,
      "the idle settle spike lost its option or held-gesture guard")
check("applied_position_seq" in idle_settle
      and "gNowCursorIdleSettledSeq" in idle_settle,
      "the idle settle spike no longer proves the application is behind")
# The spike must own its point BEFORE the manager can propagate it into
# RawMouse, or the sampler classifies the settle as physical input and
# hands the pointer back (11 guest-input exits in under a minute of 0x73
# epochs, 2026-08-13 200240).
check("remember_owned_device_point(want);" in idle_settle
      and idle_settle.index("remember_owned_device_point(want);")
          < idle_settle.index("settle_continuity_tracking_device(cell, want);"),
      "the idle settle no longer owns its point before the manager move")

# when-compression may only run on our own events: option-gated, active
# epoch only (every mouse event during an active epoch is synthetic -
# physical input exits the epoch), mouse events only, and shaped BEFORE the
# observer records `when` so the log shows what the application received.
# It exists because Finder pairs clicks against a private copy of the
# double-click time (56-tick pair failed under an active 60-tick window,
# 2026-08-13 210811) that widening the global cannot reach.
shape = body(RESIDENT, "void now_ext_continuity_shape_event(",
             "/* Capture the Event Manager's synthetic mouse record")
check("!gCompressClickWhen" in shape
      and "kNowPeekContinuityStateActive" in shape
      and "event->what != mouseDown && event->what != mouseUp" in shape,
      "when-compression lost its option, state, or event-kind gate")
check("now_continuity_when_rewrite(" in shape,
      "when-compression no longer uses the guarded pure rewrite")
# The down-to-its-own-up leg is late by hold plus manager starvation
# (55-60 ticks measured on a plain click, gen 5/6, 2026-08-13 221822) and
# broke a single-window chain exactly where compression was needed. The up
# leg gets the wider chain window; a gesture that dragged keeps its up's
# real timing and resets the chain.
check("kNowPeekContinuityHeldUpChainTicks" in shape
      and "kNowPeekContinuityWideDoubleTimeTicks" in shape,
      "the up leg no longer has its own wider chain window")
check("now_ext_cursor_tracking_press_moved()" in shape,
      "a dragged gesture's up can again be time-compressed")
check("now_ext_continuity_shape_event(event);" in EXT_CORE
      and EXT_CORE.index("now_ext_continuity_shape_event(event);")
          < EXT_CORE.index("now_ext_continuity_observe_event(event, ticks);"),
      "events are no longer shaped before the observer records them")
check('"compressClickWhen"' in WIRE
      and "kNowPeekContinuityTrackingCompressClickWhen" in WIRE,
      "the wire arm no longer maps compressClickWhen onto its option bit")

# Handing the pointer back must not leave a stale guest sprite parked at
# the last synthetic point - except on guest-input takeover, where the
# human's own hand is the next movement and wants the sprite visible.
check("ObscureCursor();" in INTAKE
      and "kNowPeekContinuityExitGuestInput" in
          INTAKE[INTAKE.index("gHaveReportedTerminal = 1;"):
                 INTAKE.index("ObscureCursor();")],
      "a handback no longer obscures the guest sprite (or obscures on takeover)")

# The interrupt-time MBState release beats the manager to the transition,
# so CursorDeviceButtonUp posts nothing: across every logged run no
# synthetic mouseUp event ever entered the queue, and a target pairing a
# down against the last mouseUp EVENT can never see a double click. The
# PPC application completes the stream in task time after each successful
# manager up; PostEvent is CarbonLib 1.0+.
check("PostEvent(mouseUp, 0)" in PPC
      and "event_down == 0 && err == noErr" in PPC,
      "the application no longer posts the mouseUp the manager cannot")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)

print("continuity event/interrupt safety source guard: ok")
