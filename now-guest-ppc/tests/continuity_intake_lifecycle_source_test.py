#!/usr/bin/env python3
"""Continuity keeps one asynchronous UDP endpoint for one TCP session.

The endpoint is transport, not authority: nonce and epoch grant authority.
Closing and immediately recreating the Open Transport endpoint at a reset
boundary partially wedged an OS 9 VM, and the first metal candidate stopped
answering TCP after one move. Authority therefore ends synchronously, while
the bound endpoint stays with the application process.

Disarm and TCP disconnect must invalidate authority immediately while leaving
the already-bound endpoint alone. The classic Process Manager reclaims it at
application exit; a port change remains the only explicit close path.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SOURCE = (ROOT / "now-guest-ppc/src/input/continuity_intake.c").read_text()
WIRE = (ROOT / "now-guest-ppc/src/core/wire.c").read_text()
CURSOR = (ROOT / "now-guest-ppc/src/input/continuity_cursor.c").read_text()
EXT_CURSOR = (ROOT / "ext/src/now_ext_cursor.c").read_text()
EXT_CONTINUITY = (ROOT / "ext/src/now_ext_continuity.c").read_text()
SERVICE = (ROOT / "now-guest-ppc/src/input/continuity_service.c").read_text()
TRACKING_PATCH = (ROOT / "ext/src/now_ext_cursor_tracking.S").read_text()


def body(name, source=SOURCE):
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


disarm = body("int now_continuity_disarm(")
disconnect = body("void now_continuity_disconnect(")
try_ack = body("static void try_send_ack(")
notifier = body("static pascal void continuity_notifier(")
take_report = body("int now_continuity_take_report(")
arm = body("int now_continuity_arm(")
open_udp = body("static int open_udp(")
shutdown = body("void now_continuity_shutdown(")
fast_pump = body("int now_continuity_wants_fast_pump(")
cursor_button = body("long now_continuity_cursor_button(", CURSOR)
cursor_move = body("long now_continuity_cursor_move(", CURSOR)
tracking_install = body(
    "int now_ext_cursor_enable_continuity_tracking(", EXT_CURSOR)
tracking_gne = body(
    "void now_ext_cursor_gne(NowPeekTable *table)\n{", EXT_CURSOR)
tracking_settle = body(
    "void now_ext_cursor_settle_continuity_tracking(", EXT_CURSOR)
tracking_device_settle = body(
    "static void settle_continuity_tracking_device(", EXT_CURSOR)
tracking_device_find = body(
    "static CursorDevicePtr continuity_tracking_device(", EXT_CURSOR)
tracking_configure = body(
    "void now_ext_cursor_configure_continuity_tracking(", EXT_CURSOR)
tracking_conflict = body(
    "static void record_continuity_tracking_conflict(", EXT_CURSOR)
tracking_remember = body(
    "void now_ext_cursor_remember_continuity_tracking_point(", EXT_CURSOR)
tracking_end = body(
    "void now_ext_cursor_end_continuity_tracking(", EXT_CURSOR)
tracking_begin = body(
    "void now_ext_cursor_begin_continuity_tracking_visuals(", EXT_CURSOR)
tracking_complete = body(
    "void now_ext_cursor_complete_continuity_tracking(", EXT_CURSOR)
release_button = body("static void release_button(", EXT_CONTINUITY)
event_result = body("static int process_event_result(", EXT_CONTINUITY)
continuity_finish = body("static void finish_locked(", EXT_CONTINUITY)
service_invoke = body("int now_continuity_service_invoke(", SERVICE)

failures = []
if "gEpoch = 0" not in disarm:
    failures.append("disarm no longer revokes UDP authority immediately")
elif disarm.index("gEpoch = 0") > disarm.index("shared->enabled = 0"):
    failures.append("disarm mutates shared control before revoking UDP authority")
if "close_udp(" in disarm:
    failures.append("disarm tears down the asynchronous Open Transport endpoint")
if "gEpoch = 0" not in disconnect:
    failures.append("TCP disconnect no longer revokes UDP authority")
elif disconnect.index("gEpoch = 0") > disconnect.index("shared = cell()"):
    failures.append("TCP disconnect reads shared state before revoking UDP authority")
if "close_udp(" in disconnect:
    failures.append("TCP disconnect tears down OT before resident reset settles")
for name, source in (("disarm", disarm), ("disconnect", disconnect),
                     ("shutdown", shutdown)):
    if "gFastPump = 0" not in source:
        failures.append(f"{name} can leave optional Fast Pump armed")
if "gEpoch != 0 && gFastPump" not in fast_pump:
    failures.append("Fast Pump is no longer bounded to a live authority epoch")
if 'now_json_find_bool(request, "fastPump", 0)' not in WIRE:
    failures.append("continuity.arm no longer defaults optional Fast Pump off")
if 'now_json_find_bool(request, "hideGuestCursorWhileDragging", 0)' not in WIRE:
    failures.append("continuity.arm no longer defaults optional cursor hiding off")
if 'now_json_find_bool(request, "virtualADB", 0)' not in WIRE:
    failures.append("continuity.arm no longer defaults optional virtual ADB off")
if "now_continuity_wants_fast_pump()" not in body(
        "Boolean conn_wants_fast_pump", WIRE):
    failures.append(
        "Continuity Fast Pump no longer reaches the existing task sleep policy")
if "endpoint retained" not in disconnect:
    failures.append("disconnect no longer records its retained transport policy")
if "kOTFlowErr" not in try_ack or "gAckPending = true" not in try_ack:
    failures.append("UDP ACK flow control no longer retains one pending ACK")
if "kOTNoDataErr" not in try_ack:
    failures.append("UDP ACK retry no longer handles transient no-data pressure")
if "gAckPending = false" not in try_ack:
    failures.append("UDP ACK completion and fatal errors no longer clear debt")
if "gNowOT.sndUData" in notifier or "try_send_ack" in notifier:
    failures.append("the Open Transport notifier again attempts an ACK send")
if "code == T_GODATA" not in notifier or "gAckGoData++" not in notifier:
    failures.append("Open Transport T_GODATA is no longer observable")
if "try_send_ack(shared)" not in take_report:
    failures.append("the task-time wire pump no longer services pending ACKs")
if "now_continuity_service_invoke(shared)" not in take_report:
    failures.append("the task-time wire pump no longer services the resident")
if "now_continuity_service_invoke(shared)" not in disarm:
    failures.append("disarm no longer settles resident authority synchronously")
if "now_continuity_service_invoke(shared)" not in disconnect:
    failures.append("disconnect no longer settles resident authority synchronously")
if "now_continuity_service_ready(shared)" not in arm:
    failures.append("arm no longer fails closed before opening the UDP lane")
if arm.index("gEpoch = (NowCU32)epoch") < arm.index(
        "now_continuity_service_invoke(shared)"):
    failures.append("arm publishes UDP authority before resident acceptance")
for field in ("adb_observer_state", "adb_observer_address",
              "adb_observer_handler_id", "adb_observer_device_count",
              "adb_observer_install_result", "adb_observer_installs",
              "adb_observer_callbacks", "adb_trace_write_seq"):
    if field not in arm:
        failures.append(
            f"arm log no longer persists ADB observer boundary field {field}")
for field in ("adb_observer_state", "adb_observer_callbacks",
              "adb_observer_reentries", "adb_trace_write_seq"):
    if field not in disarm:
        failures.append(
            f"disarm log no longer persists ADB observer boundary field {field}")
for field in ("tracking_options", "tracking_pin_writes",
              "tracking_getmouse_answers", "at_h", "at_v",
              "native_input_h", "native_input_v", "native_owned_h",
              "native_owned_v", "tracking_settle_calls",
              "tracking_settle_moved", "tracking_settle_redraws",
              "tracking_settle_reasserts", "button_edge_deferrals",
              "button_edge_overflows"):
    if field not in disarm:
        failures.append(
            f"disarm log no longer persists tracking diagnostic field {field}")
if "now_continuity_cursor_diagnostics(&cursor)" not in disarm:
    failures.append("disarm no longer snapshots the synthetic Cursor Device")
for field in ("before_request_mismatches", "press_reversions",
              "after_request_mismatches", "press_h", "press_v",
              "requested_h", "requested_v", "before_h", "before_v",
              "after_h", "after_v", "press_valid", "requested_valid",
              "after_lag_caught_up", "after_lag_persisted",
              "after_lag_pending"):
    if f"cursor.{field}" not in disarm:
        failures.append(
            f"disarm log no longer persists Cursor Device diagnostic {field}")
if "now_log_flush();" not in arm or "now_log_flush();" not in disarm:
    failures.append("ADB observer boundary can be lost before a wedge reboot")
if "if (!prepare_ack(shared))" not in try_ack:
    failures.append("UDP ACK send no longer requires a stable resident snapshot")
if "HideCursor" in SOURCE or "ShowCursor" in SOURCE:
    failures.append("Continuity intake again mutates global cursor visibility")
if "while (" in try_ack or "for (" in try_ack:
    failures.append("UDP ACK task-time retry is no longer bounded to one send")
if "gAckPublishSeq" not in try_ack:
    failures.append("task-time ACK send no longer detects notifier publication races")
if "gAckPending = false" not in disarm:
    failures.append("disarm can leave a flow-controlled ACK armed")
if "gAckPending = false" not in disconnect:
    failures.append("disconnect can leave a flow-controlled ACK armed")
if "bound_address.fPort == 0" not in open_udp:
    failures.append("UDP bind no longer refuses an unusable returned port")
if "gBoundPort = bound_address.fPort" not in open_udp:
    failures.append("UDP intake no longer retains the port OT actually bound")
if WIRE.count("(unsigned)now_continuity_udp_port()") != 3:
    failures.append("continuity reports no longer publish the actual UDP port")
if "(unsigned)g.port" in body("static int send_continuity_report(", WIRE):
    failures.append("continuity reports again publish the TCP preference as UDP")
for name, hot_path in (("button", cursor_button), ("move", cursor_move)):
    if "now_log_flush(" in hot_path:
        failures.append(
            f"cursor {name} path flushes the disk while servicing live input")
    if "now_log(kLogInfo" in hot_path:
        failures.append(
            f"cursor {name} breadcrumbs write to disk while servicing live input")
    if "now_log_memory(" not in hot_path:
        failures.append(
            f"cursor {name} path lost its allocation-free in-memory breadcrumb")
if "device_point(&device_before)" not in cursor_move \
        or "device_point(&device_after)" not in cursor_move:
    failures.append("cursor movement no longer samples its device record around MoveTo")
if "gDiagnostics.before_request_mismatches++" not in cursor_move:
    failures.append("cursor movement no longer counts pre-MoveTo record divergence")
if "gDiagnostics.press_reversions++" not in cursor_move:
    failures.append("cursor movement no longer identifies drag-origin record returns")
if "gDiagnostics.after_request_mismatches++" not in cursor_move:
    failures.append("cursor movement no longer checks the record after MoveTo")
if "gDiagnostics.after_lag_caught_up++" not in cursor_move \
        or "gDiagnostics.after_lag_persisted++" not in cursor_move:
    failures.append("cursor movement no longer classifies immediate record lag")
if "gDiagnostics.press_h = gDiagnostics.requested_h" not in cursor_button \
        or "gDiagnostics.press_v = gDiagnostics.requested_v" not in cursor_button:
    failures.append("button-down no longer binds the synthetic-device press point")
for trap in ("getmouse", "stilldown", "button"):
    label = f"now_cursor_{trap}_patch:"
    if label not in TRACKING_PATCH:
        failures.append(f"Continuity tracking lost its {trap} chain hook")
if TRACKING_PATCH.count("jmp (%a0)") != 3:
    failures.append("tracking hooks no longer tail-chain all three incumbents")
if TRACKING_PATCH.count("jsr now_ext_cursor_settle_continuity_tracking") != 3:
    failures.append("tracking hooks no longer share one bounded redraw owner")
if TRACKING_PATCH.count("movem.l %d0-%d7/%a0-%a6,-(%sp)") != 3 \
        or TRACKING_PATCH.count("movem.l (%sp)+,%d0-%d7/%a0-%a6") != 3:
    failures.append("tracking hooks no longer preserve every data/address register")
if TRACKING_PATCH.count("tst.b gNowCursorTrackingRedrawOwed") != 3:
    failures.append("idle tracking hooks no longer bypass the full save/call path")
if TRACKING_PATCH.count("tst.b gNowCursorTrackingSourceActive") != 3:
    failures.append("held tracking hooks no longer reassert the active source")
for trap in ("getmouse", "stilldown", "button"):
    if f".L{trap}_settle:" not in TRACKING_PATCH:
        failures.append(f"the {trap} hook lost its shared active/debt settle path")
if "gNowCursorTrackingRedrawOwed = 1" not in tracking_remember:
    failures.append("the timer-owned point no longer publishes redraw debt last")
if tracking_remember.index("gNowCursorTrackingRedrawOwed = 1") \
        < tracking_remember.index("remember_owned_lowmem_point"):
    failures.append("tracking redraw debt publishes before its point is complete")
for field in ("gNowCursorTrackingSourceH = pt.h",
              "gNowCursorTrackingSourceV = pt.v"):
    if field not in tracking_remember:
        failures.append("the held tracking source no longer publishes both axes")
if "gNowCursorTrackingSourceActive = 1" not in tracking_remember:
    failures.append("the timer-owned point no longer activates its tracking source")
elif tracking_remember.index("gNowCursorTrackingSourceActive = 1") \
        < tracking_remember.index("gNowCursorTrackingSourceV = pt.v"):
    failures.append("the held tracking source activates before its point is complete")
if tracking_remember.count("gNowCursorTrackingSourceSeq++") != 2:
    failures.append("the held tracking source lost its bounded publication sequence")
if "LMGetMouseLocation()" not in tracking_settle:
    failures.append("tracking settlement no longer observes ADB displacement")
for field in ("tracking_settle_calls", "tracking_settle_moved",
              "tracking_settle_redraws", "tracking_settle_reasserts"):
    if field not in tracking_settle and field not in tracking_conflict:
        failures.append(
            f"tracking settlement no longer publishes diagnostic {field}")
if tracking_settle.count("LMSetMouseLocation(pt)") != 2:
    failures.append("tracking settlement no longer reasserts before manager redraw and tail-chain")
if "gNowCursorTrackingRedrawOwed = 0" not in tracking_settle:
    failures.append("tracking redraw settlement no longer clears debt")
elif tracking_settle.index("gNowCursorTrackingRedrawOwed = 0") \
        > tracking_settle.index("HideCursor"):
    failures.append("tracking redraw can recurse before its debt is cleared")
if "if (gNowCursorTrackingSettleSyntheticDevice)\n" \
        "        settle_continuity_tracking_device(cell, pt);" \
        not in tracking_settle:
    failures.append("tracking settlement no longer reaches the opt-in device probe")
for forbidden in ("NewPtr", "DisposePtr", "WaitNextEvent", "PPostEvent",
                  "now_cdm_", "now_log"):
    if forbidden in tracking_settle:
        failures.append(f"tracking redraw reintroduced forbidden {forbidden}")
# The option gate moved to the call sites when the settle body grew a second
# caller: the gesture hook gates on SettleSyntheticDevice (0x10) and the idle
# spike gates on SettleIdleCursor (0x40) inside its own body. The shared body
# stays epoch/state bound and reentrancy-guarded either way.
if "kNowPeekContinuityTrackingSettleSyntheticDevice" \
        not in tracking_configure \
        or "if (gNowCursorTrackingSettleSyntheticDevice)" \
        not in tracking_settle:
    failures.append("synthetic-device settlement lost its explicit option gate")
if "gNowCursorTrackingDeviceActive" not in tracking_device_settle \
        or "tracking_device_reentries++" not in tracking_device_settle:
    failures.append("synthetic-device settlement lost its reentrancy guard")
if "cell->epoch == 0" not in tracking_device_settle \
        or "kNowPeekContinuityStateActive" not in tracking_device_settle:
    failures.append("synthetic-device settlement is no longer epoch/state bound")
if "device->devID == (OSType)'NOWc'" not in tracking_device_find:
    failures.append("synthetic-device discovery no longer identifies NOWc")
if "visited < 32" not in tracking_device_find \
        or "now_cdm_next_device" not in tracking_device_find:
    failures.append("synthetic-device discovery is no longer a bounded manager walk")
for forbidden in ("NewPtr", "DisposePtr", "WaitNextEvent", "PPostEvent",
                  "now_log"):
    if forbidden in tracking_device_settle or forbidden in tracking_device_find:
        failures.append(
            f"synthetic-device probe reintroduced forbidden {forbidden}")
if "gNowCursorTrackingSourceActive = 0" not in tracking_end \
        or "gNowCursorTrackingRedrawOwed = 0" not in tracking_end:
    failures.append("tracking authority exit no longer clears source and redraw debt")
if "reason != (NowPeekU32)kNowPeekContinuityExitNone" not in release_button \
        or "now_ext_cursor_end_continuity_tracking()" not in release_button:
    failures.append("forced mouse-up no longer releases tracking immediately")
elif release_button.index("now_ext_cursor_end_continuity_tracking()") \
        < release_button.index("release_button_lowmem()"):
    failures.append("tracking source clears before the unconditional low-memory release")
if "now_ext_cursor_remember_continuity_tracking_point(" not in event_result \
        or "cell->request_h, cell->request_v" not in event_result:
    failures.append("button-down no longer seeds the tracking source at the press point")
elif event_result.index("now_ext_cursor_remember_continuity_tracking_point(") \
        > event_result.index("cell->button_down = 1"):
    failures.append("button-down enters tracking before publishing its initial source")
if "now_ext_cursor_begin_continuity_tracking_visuals();" not in event_result:
    failures.append("button-down no longer starts optional tracking visuals in task time")
if "HideCursor();" not in tracking_begin:
    failures.append("the optional guest-cursor experiment no longer hides its sprite")
if "now_ext_cursor_end_continuity_tracking();" not in tracking_complete \
        or "ShowCursor();" not in tracking_complete:
    failures.append("normal release no longer ends tracking before balancing cursor visibility")
if tracking_install.count("NGetTrapAddress") < 3:
    failures.append("tracking install no longer snapshots all three incumbents")
if tracking_install.count("NSetTrapAddress") != 3:
    failures.append("tracking install no longer installs exactly three hooks")
elif tracking_install.rindex("NGetTrapAddress") \
        > tracking_install.index("NSetTrapAddress"):
    failures.append("tracking install mutates a trap before all incumbents exist")
if "kNowPeekRestCursorTrackingPatched" not in tracking_install:
    failures.append("the permanent tracking hooks are no longer observable")
for trap in ("getmouse", "stilldown", "button"):
    if f"{trap}_ours" not in tracking_install:
        failures.append(
            f"tracking install no longer detects its {trap} hook per context")
if "if (getmouse_ours && stilldown_ours && button_ours)" not in tracking_install:
    failures.append("tracking install no longer accepts an already-hooked context")
if "if (getmouse_ours || stilldown_ours || button_ours)" not in tracking_install:
    failures.append("tracking install no longer fails closed on a partial hook set")
if "gNowCursorTrackingSourceActive" not in tracking_gne \
        or "now_ext_cursor_enable_continuity_tracking()" not in tracking_gne:
    failures.append(
        "the target process no longer installs tracking hooks before its nested loop")
elif tracking_gne.index("now_ext_cursor_enable_continuity_tracking()") \
        > tracking_gne.index("if (!gTaskApplyOwed)"):
    failures.append(
        "target-context tracking install is incorrectly gated on redraw debt")
if "now_ext_cursor_enable_continuity_tracking()" not in EXT_CONTINUITY:
    failures.append("a Continuity arm no longer lazily installs tracking hooks")
if "now_ext_cursor_cancel_task_apply()" not in continuity_finish:
    failures.append("Continuity authority exit can leave tracking redraw debt")
if "kOwnedHistoryCount = 64" not in EXT_CURSOR:
    failures.append("owned Cursor Device propagation can age out before one second")
if "next + kOwnedHistoryCount - 1u - i" not in EXT_CURSOR:
    failures.append("owned-point lookup no longer checks newest reports first")
if "kNowContinuityServiceApplyRounds = 4" not in SERVICE:
    failures.append("the PPC resident handshake lost its explicit drain bound")
if "for (round = 0; round < kNowContinuityServiceApplyRounds; ++round)" \
        not in service_invoke:
    failures.append("the PPC service no longer drains resident-emitted edge chains")
if service_invoke.count("invoke_resident(cell)") < 2:
    failures.append("the PPC service no longer commits every applied result")
if "if (!published_result)" not in service_invoke:
    failures.append("the bounded PPC drain no longer stops when the handshake is quiet")

if failures:
    for failure in failures:
        print("FAIL:", failure)
    raise SystemExit(1)

print("continuity intake lifecycle source guard: ok")
