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
# THE PRESS TABOO, NARROWED DELIBERATELY (2026-08-13 225207): the Finder
# pairs clicks by its own clock at processing time, not event.when - a
# compressed pair reading 8 ticks apart failed while its dequeue spacing
# was 54 ticks - and during the Finder's own click processing nothing
# cooperative runs anywhere, so only interrupt time can put a second press
# in the queue inside its window. The resident may therefore press ONLY
# inside deliver_deferred_press_interrupt (option-gated, keyboard-plane
# PPostEvent precedent); everywhere else the old bans hold, enforced by
# counting so a second press site cannot appear silently.
deliver = body(RESIDENT,
               "static int deliver_deferred_press_interrupt(",
               "/* Raw 68K entry published in the V3 cell.")


def strip_comments(source: str) -> str:
    # Confinement is counted on CODE; the justification comments name the
    # banned calls and must not satisfy (or trip) the count.
    import re
    return re.sub(r"/\*.*?\*/", "", source, flags=re.S)


RESIDENT_CODE = strip_comments(RESIDENT)
DELIVER_CODE = strip_comments(deliver)
check("PPostEvent" in DELIVER_CODE
      and RESIDENT_CODE.count("PPostEvent") == DELIVER_CODE.count("PPostEvent")
      and "PostEvent(" not in RESIDENT_CODE.replace("PPostEvent(", ""),
      "the resident calls the Event Manager outside the confined press")
# AMENDED 2026-08-14: the V11 gate read the task-time deferred slot and
# never once fired on metal (11 deferrals / 0 deliveries, then 3 / 0) -
# the slot's lifetime never spanned a timer tick. The press now comes
# from the notifier-written wire edges, read under a torn-read snapshot
# with epoch/inside checks, and the manager-busy handshake covers the
# window between service invokes that status_seq cannot see.
check("if (!gInterruptPress)" in deliver,
      "the confined press lost its option gate")
check("gDeferredPressGeneration" not in DELIVER_CODE,
      "the confined press depends on the task-time deferred slot again")
check("before = cell->packet_seq;" in deliver
      and "before != cell->packet_seq" in deliver,
      "the confined press reads wire edges without a torn-read snapshot")
check("packet_epoch != cell->epoch" in deliver
      and "kNowPeekContinuityInside" in deliver,
      "the confined press no longer checks epoch and inside before pressing")
check("cell->button_manager_busy" in deliver,
      "the confined press ignores the manager-busy handshake")
check("now_continuity_button_action(" in deliver
      and "previous_generation, previous_flags" in deliver,
      "the confined press no longer derives the press from both edge slots")
check(deliver.index("PPostEvent(mouseUp")
          < deliver.index("LMSetMouseButtonState(0x00)")
      and deliver.index("LMSetMouseButtonState(0x00)")
          < deliver.index("PPostEvent(mouseDown"),
      "the confined press no longer completes click 1 before pressing")
check("cell->event_request_generation = 0;" in deliver
      and "cell->pending_mouseup = 0;" in deliver,
      "the confined press no longer cancels the pending manager up")
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
check("position_seq, cell->request_position_seq" in tick
      and "cell->applied_position_seq = position_seq" not in tick,
      "the timer again claims a manager apply or repeats one tracking point")
check("LMSetMouseButtonState(0x80)" in release
      and RESIDENT_CODE.count("LMSetMouseButtonState(0x00)")
          == DELIVER_CODE.count("LMSetMouseButtonState(0x00)"),
      "the resident presses MBState outside the confined press")
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
check("*gCrsrObscure = 0" in reveal
      and "HideCursor();" in reveal and "ShowCursor();" in reveal,
      "Continuity no longer reproduces the native mouse visibility wake")
check("now_ext_cursor_end_continuity_tracking();" in tracking_complete,
      "normal release no longer revokes the held tracking source")

# RETIRED 2026-08-14: four experiments predated the blessed settle/input
# mechanisms and are deliberately absent from the resident. Their accretive
# contract bits and counters remain reserved, but no resident branch may make
# them active again. The passive ADB observer and its injection transform were
# diagnostic scaffolding for a closed investigation, so their implementation
# files and build edges are gone rather than left dormant and callable.
for retired in (
        "kNowPeekContinuityTrackingPinHeldPoint",
        "kNowPeekContinuityTrackingVirtualGetMouse",
        "kNowPeekContinuityTrackingHideGuestCursor",
        "kNowPeekContinuityTrackingVirtualADB"):
    check(retired not in RESIDENT and retired not in CURSOR,
          f"retired resident experiment is still executable: {retired}")
check("now_ext_cursor_answer_continuity_getmouse" not in TRACKING_ASM,
      "the retired Virtual GetMouse answer path remains in the trap shim")
for retired_path in (
        "ext/src/now_ext_adb_observer.c",
        "ext/src/now_ext_adb_observer.S",
        "ext/src/now_ext_adb_observer.h",
        "now-guest-shared/src/now_adb_injection_logic.c",
        "now-guest-shared/src/now_adb_injection_logic.h"):
    check(not (ROOT / retired_path).exists(),
          f"retired ADB implementation remains: {retired_path}")
check("now_ext_adb_observer" not in EXT_CMAKE
      and "now_adb_injection_logic" not in EXT_CMAKE,
      "the extension still links the retired ADB implementation")
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
check("releasePending" not in HOST
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
                   "NowPeekU32 now_ext_cursor_idle_settled_seq(")
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
# One Cursor Device, two drivers: the spike settles from whatever process
# pumps, and the application's pump applies whatever request the cell
# exposes. They are made exclusive BY SEQUENCE - a sequence the spike has
# settled is never published as a request, or the application re-applies a
# point the device is already past (a backward move plus duplicate manager
# work). The option bit is tested at the service, so the exposure path with
# the bit clear is unchanged whatever the wire sequence has reached.
check("NowPeekU32 now_ext_cursor_idle_settled_seq(void)" in CURSOR
      and "return gNowCursorIdleSettledSeq;" in CURSOR,
      "the settled sequence is no longer readable by the service")
exposure = body(RESIDENT, "static int idle_settle_already_drew(",
                "static void status_begin(")
check("kNowPeekContinuityTrackingSettleIdleCursor" in exposure,
      "the single-driver exclusion no longer proves the spike is even armed")
check("now_ext_cursor_idle_settled_seq()" in exposure
      and "!now_continuity_sequence_newer(" in exposure,
      "the exclusion no longer compares against the spike's settled sequence")
check("&& !idle_settle_already_drew(cell, position_seq)" in service,
      "the service again exposes a request the idle spike already drew")
# A settle the manager ACCEPTED is this resident answering the wire, so it
# owns the acknowledgement currency too - otherwise the host's acks describe
# a point no driver reports reaching. Advance only; a settle may run ahead of
# an older applied sequence but must never walk one back.
check("cell->tracking_device_moves != moves_before" in idle_settle
      and "cell->applied_position_seq = position_seq;" in idle_settle,
      "a successful idle settle no longer advances the acknowledged sequence")
check("now_continuity_sequence_newer(position_seq,\n"
      "                                                 "
      "cell->applied_position_seq)" in idle_settle,
      "the idle settle can now walk the acknowledged sequence backwards")

# The Process Manager's front process is the one a click is dispatched
# against; the menu bar and switcher are layer state and have shown Finder
# front through failing double clicks. One FILE-logged line per accepted
# press - now_log_memory never reaches an uploaded log.
front = body(PPC, "static void log_front_process_at_down(",
             "static void record_button_timing(")
check("GetFrontProcess(&psn)" in front
      and "GetProcessInformation(&psn, &info)" in front,
      "the front-process evidence no longer asks the Process Manager")
check("now_log(kLogInfo" in front and "now_log_memory" not in front,
      "the front-process line went to memory, where uploads never see it")
check("if (length > 31)" in front,
      "the foreign process name is copied without a bound")
# Indent tracks the V12 busy handshake, which nests the manager call one
# level deeper; the pin is about the pairing, not the column.
check("if (event_down != 0 && err == noErr)\n"
      "                    log_front_process_at_down(event_generation);" in PPC,
      "the front process is no longer captured at an accepted manager down")

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

# V12 MANAGER-BUSY HANDSHAKE. The manager call sits BETWEEN resident invokes,
# where status_seq is even and the resident's mid-invoke guard sees nothing at
# all, so the interrupt-press delivery has exactly one way to learn that an
# exposed request is already being served: this flag. It is only a handshake if
# the flag is up before the call and the request is re-read after raising it -
# a flag raised after the read closes nothing, and a flag cleared before the
# result is published re-opens the window it exists to shut.
invoke = body(PPC, "int now_continuity_service_invoke(",
              "void now_continuity_service_begin_epoch(")
BUSY_SET = "cell->button_manager_busy = 1;"
BUSY_CLEAR = "cell->button_manager_busy = 0;"
check(BUSY_SET in invoke
      and BUSY_CLEAR in invoke
      and invoke.index(BUSY_SET) < invoke.index("now_continuity_cursor_button(")
      and invoke.index("cell->event_result_generation = event_generation;")
          < invoke.rindex(BUSY_CLEAR),
      "the manager call is unannounced to the interrupt press, or clears its "
      "busy flag before the result it protects is published")
check(BUSY_SET in invoke
      and "cell->event_request_generation != event_generation" in invoke
      and "cell->event_request_down != event_down" in invoke
      and invoke.index(BUSY_SET)
          < invoke.index("cell->event_request_generation != event_generation")
          < invoke.index("now_continuity_cursor_button("),
      "the exposed request is not re-read after the busy flag goes up, so a "
      "delivery that cancelled first is still served")
# The probe drain's own window: a cell that resets under an armed drain turns
# the unsigned subtraction into a four-billion-entry window, which prints as
# zeroed rows and reads exactly like a live probe capturing nothing.
click_drain = body(PPC, "static void drain_click_probe(",
                   "int now_continuity_service_ready(")
check("total < gLastClickProbeCount" in click_drain
      and "click probe reset" in click_drain,
      "a click probe reset again underflows the drain window instead of "
      "re-baselining and saying so")

# The V11 deep click probe is a RECORDER: it exists because both timestamp
# theories of the double-click failure died by measurement, and its whole
# value is that it observes without participating. A capture that posts,
# sets state, logs, allocates, or re-primes a timer is a new input source
# wearing a diagnostic's name.
capture = body(RESIDENT, "/* V11 deep click probe: READS ONLY.",
               "static void release_button(")
for token in ("PPostEvent", "PostEvent", "LMSet", "PrimeTime", "now_log",
              "NewPtr", "DisposePtr", "GetFrontProcess", "now_cdm_"):
    check(token not in capture,
          f"the deep click probe stopped being read-only: {token}")
check("if (!gDeepClickLog)" in capture
      and "event->what != mouseDown && event->what != mouseUp" in capture,
      "the deep click probe lost its latch or event-kind gate")
check("guard < 32" in capture,
      "the raw event-queue walk lost its iteration bound")
check("% (NowPeekU32)kNowPeekContinuityClickProbeCapacity" in capture
      and "entry->write_seq = seq + 2u;" in capture,
      "the probe ring lost its rolling index or its commit-last seqlock")

# The latch is written in exactly one place - epoch start - and survives
# every exit path on purpose: the native half of the comparison can only
# be clicked after takeover has already ended the epoch. A second writer
# (an exit-path clear is the tempting one) silently amputates that half.
check(RESIDENT.count("gDeepClickLog =") == 2
      and "gDeepClickLog = (cell->tracking_options" in
          body(RESIDENT, "static void start_epoch_locked(",
               "static void apply_button_edge("),
      "the deep-click latch gained a writer outside start_epoch_locked")

# The capture must run ahead of the enabled gate, or disarm/takeover cuts
# the recording exactly when the native comparison clicks happen.
observe = body(RESIDENT, "void now_ext_continuity_observe_event(",
               "/* V11 deep click probe: READS ONLY.")
check(observe.index("deep_click_capture(cell, event, ticks);")
          < observe.index("if (!cell->enabled)"),
      "the deep click probe no longer records after epoch exit")

# The drain is uploadable evidence: now_log, never now_log_memory, and an
# overrun is counted out loud rather than silently absent.
probe_drain = body(PPC, "static void drain_click_probe(",
                   "int now_continuity_service_ready(")
check("now_log_memory" not in probe_drain
      and "now_log(" in probe_drain,
      "the click probe drain fell back to the never-uploaded memory log")
check("click_probe_overwritten +=" in probe_drain
      and "click probe overran drain" in probe_drain,
      "a probe overrun is no longer counted and named")

# The host and wire both know the flag, or the toggle arms nothing.
check("deepClickLog" in WIRE
      and "kNowPeekContinuityTrackingDeepClickLog" in WIRE,
      "the wire no longer maps deepClickLog onto tracking bit 9")
check(".init(id: .deepClickLog" in HOST
      and "armOptions[option.id] = self[keyPath: option.keyPath]" in HOST,
      "the host arm no longer forwards the deep click probe flag")

# MBTicks coherence. Native downs satisfy when == MBTicks exactly (26/26,
# probe run 015913); when-compression forged `when` and left the driver's
# copy contradicting it by up to 110 ticks. The forgery is now coherent -
# and confined: exactly two writers, the shape rewrite and the interrupt
# press, both moving MBTicks WITH the state they already own.
check(RESIDENT.count("LMSetMBTicks") == 2,
      "MBTicks gained or lost a writer outside shape and the confined press")
check("LMSetMBTicks((long)event->when)" in shape
      and shape.index("now_continuity_when_rewrite(")
          < shape.index("LMSetMBTicks(")
      and "if (is_down)" in shape,
      "the shape rewrite no longer keeps MBTicks coherent on downs")
check("LMSetMBTicks((long)ticks)" in deliver
      and deliver.index("LMSetMouseButtonState(0x00)")
          < deliver.index("LMSetMBTicks(")
      and deliver.index("LMSetMBTicks(")
          < deliver.index("PPostEvent(mouseDown"),
      "the confined press no longer moves MBTicks with MBState")

# An interrupt delivery can apply the NEXT press while an older up's
# manager call is in flight; committing the older generation afterwards
# regresses the ledger and re-arms the same press twice.
result_up = result[result.index("cell->pending_mouseup) {"):]
check("now_continuity_sequence_newer(" in
          result_up[:result_up.index("applied_button_generation = generation")],
      "a settled up can again regress an interrupt-delivered press")

# THE EXPOSURE BARRIER. Applying a position is not exposing it: the Cursor
# Device record is upstream of the mouse global that every guest tracking
# loop samples, and until 2026-08-15 a round applied the position request
# and then acted on it in adjacent instructions. On metal the release beat
# the propagation and the Finder completed a move at the screen edge instead
# of the settled press origin - a real relocation out of a Finder window.
# The host's packet order was never the missing guarantee (the wire is a
# latest-state mailbox and both packets carried the same point); the barrier
# between applying a point and acting on it was.
AWAIT = "now_continuity_cursor_await_exposure(&exposure)"
check(AWAIT in invoke
      and invoke.index(AWAIT) < invoke.index("now_continuity_cursor_button(")
      and invoke.index(AWAIT) < invoke.index(BUSY_SET),
      "a button edge is applied without waiting for its own position to be "
      "exposed, or waits while holding the manager-busy flag up")
# One FILE-logged line per edge naming applied against exposed. Without it a
# metal round cannot tell a barrier that held from a barrier that never had
# anything to hold, and "the icon landed in the wrong place" says neither.
# Sliced defensively: a missing or misplaced wait is the check above's
# sentence to say, and this one must not pre-empt it with a traceback.
edge_log = invoke[invoke.index(AWAIT):] if AWAIT in invoke else ""
if BUSY_SET in edge_log:
    edge_log = edge_log[:edge_log.index(BUSY_SET)]
check("now_log(" in edge_log
      and "now_log_memory" not in edge_log
      and "applied=%ld,%ld" in edge_log
      and "exposed=%ld,%ld" in edge_log
      and "waited=%lu" in edge_log,
      "the per-edge exposure line is gone, went to the never-uploaded memory "
      "log, or stopped naming applied against exposed")
check("kNowContinuityBarrierExpired" in edge_log,
      "an edge applied on the deadline is no longer distinguishable from one "
      "whose position was actually exposed")

# The wait itself: Carbon's accessor, the guarded pure decision, and a spin
# rather than a yield. The caller that needs this most is a release inside
# the Finder's drag loop, which is exactly where further task time may never
# come back - yielding there trades a wrong drop point for a stuck drag.
await_body = body(PPC_CURSOR, "int now_continuity_cursor_await_exposure(",
                  "void now_continuity_cursor_diagnostics(")
check("GetGlobalMouse(&global)" in await_body
      and "LMGetMouseLocation" not in await_body,
      "the exposure test no longer asks the global the guest's tracking "
      "loops sample, through the accessor Carbon promises")
# Both stages, not just the nearer one. A QEMU round measured the record
# lagging five times while the global was never behind at an edge, so a
# barrier that asked the global alone was silent through all five.
check("device_point(&record)" in await_body
      and "state.observed_is_record = 1;" in await_body,
      "the exposure test stopped asking the device record, which is upstream "
      "of the global and can be behind while the global reads settled")
check("now_continuity_button_barrier(" in await_body,
      "the exposure wait no longer uses the guarded pure barrier")
check("kNowContinuityExposureDeadlineTicks" in await_body,
      "the exposure spin lost its deadline and can now hold an edge forever")
for yielder in ("WaitNextEvent", "SystemTask", "now_continuity_pump",
                "now_wire_pump"):
    check(yielder not in await_body,
          "the exposure spin yields (%s), so a starved drag loop can strand "
          "a held button" % yielder)

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)

print("continuity event/interrupt safety source guard: ok")
