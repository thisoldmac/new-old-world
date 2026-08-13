/* P9 Continuity vehicle. Network parsing and scheduling belong to the PPC
   application. Its cooperative wire pump enters now_ext_continuity_service
   through Mixed Mode; this resident consumes one preallocated latest-state
   cell, publishes one requested point, and commits only the result returned by
   the PPC application's Apple CursorDevicesGlue call. */
#include <LowMem.h>
#include <MacTypes.h>
#include <Timer.h>

#include <string.h>

#include "peek_table.h"
#include "now_continuity_logic.h"
#include "now_ext_core_logic.h"
#include "now_ext_adb_observer.h"
#include "now_ext_continuity_keyboard.h"
#include "now_ext_cursor_input.h"
#include "now_input_owner.h"

static NowPeekTable *gTable;
static Boolean gInstalled;
static volatile Boolean gServiceActive;
static volatile Boolean gPrimed;
static volatile NowPeekU32 gNativeInputSeq;
static volatile NowPeekU32 gNativeInputBaseline;

/* Cursor Device Manager calls belong to the PPC app. These counters retain
   their accretive names, but report the request/result handshake and forced
   release rather than Event Manager posts. */
static volatile NowPeekU32 gForcedResets;
static volatile NowPeekU32 gEventResetGeneration;
static volatile NowPeekU32 gTasktimeCursorApplies;

typedef struct {
    TMTask task;                /* first: the Time Manager owns this */
    NowPeekTable *table;
} ContinuityButtonTask;

static ContinuityButtonTask gButtonTask;
static Boolean gButtonTaskInstalled;
static volatile Boolean gButtonTaskRunning;
static volatile NowPeekU32 gReleaseSettleStarted;

static NowPeekU32 native_input_sequence(const NowPeekContinuityCell *cell)
{
    if (cell != NULL
            && (cell->tracking_options
                & (NowPeekU32)kNowPeekContinuityTrackingVirtualADB) != 0)
        return now_ext_adb_observer_physical_seq();
    return now_ext_cursor_physical_input_seq();
}

enum { kNowContinuityReleaseSettleMaxTicks = 60 };

extern void now_ext_continuity_tm_entry(void);
void now_ext_continuity_tick(TMTaskPtr task);

static NowPeekContinuityCell *continuity_cell(NowPeekTable *table)
{
    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic)
        return NULL;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                     + sizeof(NowPeekContinuityCell)))
        return NULL;
    if (table->continuity_format
            != (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT)
        return NULL;
    return &table->continuity;
}

static void status_begin(NowPeekContinuityCell *cell)
{
    cell->status_seq++;
}

static void status_end(NowPeekContinuityCell *cell)
{
    cell->status_seq++;
}

static void trace_event(NowPeekContinuityCell *cell, NowPeekU32 event,
                        NowPeekU32 ticks, NowPeekI32 arg0, NowPeekI32 arg1)
{
    NowPeekU32 seq = cell->trace_write_seq + 1u;
    NowPeekContinuityTraceEntry *entry;

    if (seq == 0)
        seq = 1;
    entry = &cell->trace[(seq - 1u) % kNowPeekContinuityTraceCapacity];
    entry->event = event;
    entry->ticks = ticks;
    entry->arg0 = arg0;
    entry->arg1 = arg1;
    entry->seq = seq;                 /* commit the entry last */
    cell->trace_write_seq = seq;
}

static void service_return(NowPeekContinuityCell *cell)
{
    status_end(cell);
    gServiceActive = false;
}

static void publish_tasktime_counters(NowPeekContinuityCell *cell)
{
    NowCursorInputDiagnostics input;

    cell->tasktime_cursor_applies = gTasktimeCursorApplies;
    cell->forced_resets = gForcedResets;
    cell->event_reset_generation = gEventResetGeneration;
    now_ext_cursor_input_diagnostics(&input);
    cell->native_input_samples = input.samples;
    cell->native_input_changes = input.changes;
    cell->native_input_trigger = input.trigger;
    cell->native_input_h = input.h;
    cell->native_input_v = input.v;
    cell->native_owned_h = input.owned_h;
    cell->native_owned_v = input.owned_v;
    cell->native_buttons = input.buttons;
    cell->native_physical_valid = input.physical_valid;
    cell->native_owned_valid = input.owned_valid;
    cell->cursor_debt_cancels = input.debt_cancels;
}

static void release_button_lowmem(void)
{
    LMSetMouseButtonState(0x80);
    now_ext_cursor_remember_continuity_button(0u);
}

static void request_button(NowPeekContinuityCell *cell,
                           NowPeekU32 generation, int down)
{
    if (generation == 0)
        return;
    /* Invalidate the old commit before changing its direction. Otherwise the
       PPC reader can pair the preceding generation with this new direction
       when a Time Manager release interrupts its snapshot. */
    cell->event_request_generation = 0;
    cell->event_request_down = down ? 1u : 0u;
    cell->event_request_generation = generation; /* commit last */
}

static void release_button(NowPeekContinuityCell *cell,
                           NowPeekU32 generation, NowPeekU32 reason)
{
    NowPeekU32 release_generation = generation;

    if (!cell->button_down)
        return;
    /* MBState-up is first and unconditional. Everything after it is
       telemetry or task-time event debt and cannot leave the Mac held. */
    release_button_lowmem();
    if (reason != (NowPeekU32)kNowPeekContinuityExitNone)
        now_ext_cursor_end_continuity_tracking();
    cell->button_down = 0;
    cell->pending_mouseup = 1;
    if (release_generation == 0
            || !now_continuity_sequence_newer(
                release_generation, cell->applied_button_generation)) {
        if (reason == (NowPeekU32)kNowPeekContinuityExitNone) {
            /* A duplicate host up needs no second manager transition. */
            cell->pending_mouseup = 0;
            now_ext_cursor_end_continuity_tracking();
            gButtonTaskRunning = false;
            return;
        }
        /* A dead-man release has no host-authored generation of its own.
           Give it a new commit value so a PPC reader can never combine the
           old press generation with the new up direction. The epoch exits,
           so this synthetic generation cannot collide with later input. */
        release_generation = cell->applied_button_generation + 1u;
        if (release_generation == 0)
            release_generation = 1;
    }
    if (reason != (NowPeekU32)kNowPeekContinuityExitNone) {
        cell->button_forced_releases++;
        cell->button_release_reason = reason;
    }
    /* Do not acknowledge this generation until CursorDeviceButtonUp returns.
       The low-memory release is already safe, but advancing the ACK here lets
       the host start another press and overwrite this manager-up debt. */
    request_button(cell, release_generation, 0);
    if (reason == (NowPeekU32)kNowPeekContinuityExitNone) {
        /* Keep the held source through the target's final tracking redraw and
           the PPC manager-up/final-position handshake. A bounded timer may
           revoke only that source if cooperative task time never returns. */
        gReleaseSettleStarted = (NowPeekU32)LMGetTicks();
        gButtonTaskRunning = true;
        PrimeTime((QElemPtr)&gButtonTask.task,
                  (long)kNowPeekContinuityTickMs);
    } else {
        gButtonTaskRunning = false;
    }
}

static int process_event_result(NowPeekContinuityCell *cell,
                                NowPeekU32 ticks)
{
    NowPeekU32 generation = cell->event_request_generation;
    int down = cell->event_request_down != 0;

    if (generation == 0
            || cell->event_result_generation != generation
            || cell->event_result_down != cell->event_request_down)
        return 0;
    if (down) {
        if (cell->button_down
                || !now_continuity_sequence_newer(
                    generation, cell->applied_button_generation))
            return 0;
        if (cell->event_result_err != noErr) {
            cell->event_post_failures++;
            cell->button_release_reason =
                (NowPeekU32)kNowPeekContinuityExitUnavailable;
            return 0;
        }
        /* CursorDeviceButtonDown already established the system's button
           state. Teach the physical-input sampler that this transition was
           ours before sampling position, then arm the interrupt-time escape
           path. The resident never impersonates the ADB/PMU device on down. */
        now_ext_cursor_remember_continuity_button(1u);
        if (!(cell->tracking_options
                & (NowPeekU32)kNowPeekContinuityTrackingVirtualADB)) {
            gNativeInputSeq = native_input_sequence(cell);
            gNativeInputBaseline = gNativeInputSeq;
        }
        /* Publish the press point before the target enters its nested loop.
           The timer replaces it with newer host points while held. */
        now_ext_cursor_remember_continuity_tracking_point(
            cell->request_h, cell->request_v);
        now_ext_cursor_begin_continuity_tracking_visuals();
        cell->button_down = 1;
        cell->applied_button_generation = generation;
        cell->event_down_posts++;
        cell->button_release_reason =
            (NowPeekU32)kNowPeekContinuityExitNone;
        gButtonTaskRunning = true;
        PrimeTime((QElemPtr)&gButtonTask.task,
                  (long)kNowPeekContinuityTickMs);
        trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceApplied,
                    ticks, (NowPeekI32)generation, 1);
        return 0;
    } else if (cell->pending_mouseup) {
        if (cell->event_result_err == noErr) {
            cell->event_up_posts++;
            cell->applied_button_generation = generation;
        } else {
            cell->event_post_failures++;
            cell->button_release_reason =
                (NowPeekU32)kNowPeekContinuityExitUnavailable;
        }
        /* MBState is already up. A manager refusal exits the epoch rather
           than retrying forever or acknowledging an unsettled transition. */
        cell->pending_mouseup = 0;
        return cell->event_result_err == noErr;
    }
    return 0;
}

static void force_reset(NowPeekContinuityCell *cell, NowPeekU32 reason)
{
    release_button(cell, cell->button_generation, reason);
    gForcedResets++;
    gEventResetGeneration++;
}

static void finish_locked(NowPeekContinuityCell *cell, NowPeekU32 reason,
                          NowPeekU32 ticks)
{
    force_reset(cell, reason);
    now_ext_cursor_cancel_task_apply();
    now_ext_continuity_keyboard_flush(cell);
    now_ext_cursor_configure_continuity_tracking(0);
    now_ext_adb_observer_stop();
    cell->state = (NowPeekU32)kNowPeekContinuityStateExited;
    cell->exit_reason = reason;
    cell->apply_ticks = ticks;
    cell->request_position_seq = 0;
    if (reason == (NowPeekU32)kNowPeekContinuityExitGuestInput)
        cell->local_takeovers++;
    publish_tasktime_counters(cell);
    now_input_owner_release(kNowInputOwnerContinuity);
    gPrimed = false;
    trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceExit, ticks,
                (NowPeekI32)reason, (NowPeekI32)cell->applied_position_seq);
}

static void start_epoch_locked(NowPeekContinuityCell *cell, NowPeekU32 ticks)
{
    /* The caller has already proved there is no held button or owed up event.
       Never erase those debts to make a new epoch look clean. */
    cell->state = (NowPeekU32)kNowPeekContinuityStateArmed;
    cell->exit_reason = (NowPeekU32)kNowPeekContinuityExitNone;
    cell->accepted_hz = now_continuity_accept_rate(cell->requested_hz);
    cell->last_arrival_ticks = ticks;
    cell->observed_packet_seq = cell->packet_seq;
    cell->applied_position_seq = 0;
    cell->request_position_seq = 0;
    cell->applied_button_generation = 0;
    cell->event_request_generation = 0;
    cell->event_request_down = 0;
    cell->event_result_generation = 0;
    cell->event_result_down = 0;
    cell->event_result_err = 0;
    cell->pending_mouseup = 0;
    cell->button_release_reason = 0;
    now_ext_continuity_keyboard_flush(cell);
    now_ext_cursor_configure_continuity_tracking(cell->tracking_options);
    gNativeInputSeq = native_input_sequence(cell);
    gNativeInputBaseline = gNativeInputSeq;
    now_ext_adb_observer_start(
        gTable, cell->epoch,
        cell->tracking_options
            & (NowPeekU32)kNowPeekContinuityTrackingVirtualADB);
    publish_tasktime_counters(cell);
}

/* Raw 68K entry published in the V3 cell. It is not a PPC function pointer:
   the application wraps the address in a kM68kISA|kOld68kRTA descriptor and
   calls it variadically through CallUniversalProc. No args keeps the ABI seam
   minimal; all input and output already live in the versioned shared cell. */
void now_ext_continuity_service(void)
{
    NowPeekContinuityCell *cell;
    NowPeekU32 ticks;
    NowPeekU32 before;
    NowPeekU32 packet_epoch;
    NowPeekU32 position_seq;
    NowPeekU32 flags;
    NowPeekU32 arrival;
    NowPeekI32 h;
    NowPeekI32 v;
    NowPeekU32 native_input_seq;
    NowPeekU32 exit_due;
    int release_settled;

    if (!gInstalled)
        return;
    cell = continuity_cell(gTable);
    if (cell == NULL)
        return;
    ticks = (NowPeekU32)LMGetTicks();
    if (gServiceActive) {
        cell->service_reentries++;
        return;
    }
    gServiceActive = true;

    status_begin(cell);
    cell->service_calls++;
    trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceServiceEnter,
                ticks, (NowPeekI32)cell->state,
                (NowPeekI32)cell->packet_seq);

    release_settled = process_event_result(cell, ticks);
    if (cell->button_release_reason
            == (NowPeekU32)kNowPeekContinuityExitUnavailable) {
        finish_locked(cell,
                      (NowPeekU32)kNowPeekContinuityExitUnavailable, ticks);
        service_return(cell);
        return;
    }
    if (cell->button_release_reason
            == (NowPeekU32)kNowPeekContinuityExitGuestInput
            || cell->button_release_reason
                == (NowPeekU32)kNowPeekContinuityExitLeaseExpired
            || cell->button_release_reason
                == (NowPeekU32)kNowPeekContinuityExitHostLeft) {
        NowPeekU32 reason = cell->button_release_reason;
        cell->button_release_reason = 0;
        finish_locked(cell, reason, ticks);
        service_return(cell);
        return;
    }

    /* Authority/reset wins over every stale datagram. The application calls
       this immediately after arm/disarm/disconnect as well as from every
       ordinary and nested wire pump. A starved app cannot serve this branch,
       so the held-button timer independently owns MBState-up and the lease. */
    if (cell->control_seq != cell->observed_control_seq) {
        cell->observed_control_seq = cell->control_seq;
        if (!cell->enabled || cell->epoch == 0) {
            finish_locked(cell,
                          (NowPeekU32)kNowPeekContinuityExitDisarmed, ticks);
            service_return(cell);
            return;
        }
        if (!gPrimed
            && !now_input_owner_acquire(kNowInputOwnerContinuity)) {
            cell->state = (NowPeekU32)kNowPeekContinuityStateRefused;
            cell->exit_reason =
                (NowPeekU32)kNowPeekContinuityExitUnavailable;
            publish_tasktime_counters(cell);
            service_return(cell);
            return;
        }
        if (!gPrimed
            && !now_ext_cursor_enable_continuity_tracking()) {
            now_input_owner_release(kNowInputOwnerContinuity);
            cell->state = (NowPeekU32)kNowPeekContinuityStateRefused;
            cell->exit_reason =
                (NowPeekU32)kNowPeekContinuityExitUnavailable;
            publish_tasktime_counters(cell);
            service_return(cell);
            return;
        }
        if (cell->button_down || cell->pending_mouseup) {
            finish_locked(cell,
                          (NowPeekU32)kNowPeekContinuityExitDisarmed, ticks);
            service_return(cell);
            return;
        }
        start_epoch_locked(cell, ticks);
        gPrimed = true;
        trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceControl,
                    ticks, (NowPeekI32)cell->epoch,
                    (NowPeekI32)cell->accepted_hz);
    }

    if (!gPrimed) {
        publish_tasktime_counters(cell);
        service_return(cell);
        return;
    }

    /* CursorDevicesGlue ran in the PPC application between service calls.
       Commit only the exact request this resident published; a stale result
       from a prior epoch or coalesced point cannot move resident authority. */
    if (cell->apply_result_seq != 0
            && cell->apply_result_seq == cell->request_position_seq
            && now_continuity_sequence_newer(
                cell->apply_result_seq, cell->applied_position_seq)) {
        if (cell->apply_result_err != 0) {
            trace_event(cell,
                        (NowPeekU32)kNowPeekContinuityTraceApplyError,
                        ticks, cell->apply_result_err,
                        (NowPeekI32)cell->apply_result_seq);
            finish_locked(cell,
                          (NowPeekU32)kNowPeekContinuityExitUnavailable,
                          ticks);
            service_return(cell);
            return;
        }
        now_ext_cursor_remember_continuity_point(cell->request_h,
                                                 cell->request_v);
        now_ext_cursor_reveal_continuity();
        gTasktimeCursorApplies++;
        cell->at_h = cell->request_h;
        cell->at_v = cell->request_v;
        cell->applied_position_seq = cell->apply_result_seq;
        cell->apply_ticks = ticks;
        trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceApplied,
                    ticks, (NowPeekI32)cell->applied_position_seq,
                    cell->at_h);
    }
    if (release_settled) {
        now_ext_cursor_complete_continuity_tracking();
        gButtonTaskRunning = false;
    }

    /* Passive mode samples RawMouse. Virtual-ADB mode instead trusts the
       wrapper's exact packet classification, because the incumbent's later
       system update is downstream of both injected and physical packets. */
    native_input_seq = native_input_sequence(cell);
    gNativeInputSeq = native_input_seq;
    if (native_input_seq != gNativeInputBaseline) {
        gNativeInputBaseline = native_input_seq;
        finish_locked(cell,
                      (NowPeekU32)kNowPeekContinuityExitGuestInput, ticks);
        service_return(cell);
        return;
    }
    if (cell->tracking_options
            & (NowPeekU32)kNowPeekContinuityTrackingVirtualADB) {
        Point actual = LMGetMouseLocation();

        cell->at_h = actual.h;
        cell->at_v = actual.v;
        if (actual.h == (short)cell->want_h
                && actual.v == (short)cell->want_v
                && now_continuity_sequence_newer(
                    cell->position_seq, cell->applied_position_seq)) {
            cell->applied_position_seq = cell->position_seq;
            cell->apply_ticks = ticks;
        }
    }
    exit_due = now_continuity_exit_due(
        ticks, cell->last_arrival_ticks,
        now_continuity_lease_for_state(cell->state, cell->lease_ticks),
        0, 0, 0, 0, 0, 0, 0, 0);
    if (exit_due != (NowPeekU32)kNowPeekContinuityExitNone) {
        finish_locked(cell, exit_due, ticks);
        service_return(cell);
        return;
    }

    before = cell->packet_seq;
    if (before != cell->observed_packet_seq) {
        packet_epoch = cell->packet_epoch;
        position_seq = cell->position_seq;
        h = cell->want_h;
        v = cell->want_v;
        flags = cell->flags;
        arrival = cell->arrival_ticks;
        if (before != cell->packet_seq) {
            publish_tasktime_counters(cell);
            service_return(cell);
            return;
        }
        cell->observed_packet_seq = before;
        if (packet_epoch != cell->epoch) {
            cell->stale_packets++;
        } else if (!(flags & kNowPeekContinuityInside)) {
            finish_locked(cell,
                          (NowPeekU32)kNowPeekContinuityExitHostLeft, ticks);
            service_return(cell);
            return;
        } else {
            cell->accepted_packets++;
            cell->last_arrival_ticks = arrival;
            cell->state = (NowPeekU32)kNowPeekContinuityStateActive;
            if (now_continuity_sequence_newer(
                    position_seq, cell->applied_position_seq)) {
                if (!(cell->tracking_options
                        & (NowPeekU32)kNowPeekContinuityTrackingVirtualADB)) {
                    cell->request_h = h;
                    cell->request_v = v;
                    cell->request_position_seq = position_seq;
                }
                trace_event(cell,
                            (NowPeekU32)kNowPeekContinuityTraceRequest,
                            ticks, (NowPeekI32)position_seq, h);
            }
            switch (now_continuity_button_action(
                        cell->applied_button_generation,
                        cell->button_down != 0,
                        cell->button_generation, flags)) {
                case kNowContinuityButtonPress:
                    request_button(cell, cell->button_generation, 1);
                    break;
                case kNowContinuityButtonRelease:
                    /* Task-time fast path. The timer performs this same
                       release when a tracking loop has starved the app. */
                    release_button(cell, cell->button_generation,
                                   (NowPeekU32)kNowPeekContinuityExitNone);
                    break;
                default:
                    break;
            }
        }
    }
    publish_tasktime_counters(cell);
    service_return(cell);
}

/* Held-input vehicle. INTERRUPT TIME: MouseLocation, emergency MBState-up and
   resident fields only. RawMouse and MTemp belong to the physical ADB/PMU
   path; touching either from this unrelated timer caused the metal wedge this
   split exists to prevent. There is no manager, Event Manager, QuickDraw,
   Process Manager, allocation or logging here. */
void now_ext_continuity_tick(TMTaskPtr task)
{
    ContinuityButtonTask *self = (ContinuityButtonTask *)task;
    NowPeekContinuityCell *cell;
    NowPeekU32 before;
    NowPeekU32 ticks;
    NowPeekU32 epoch;
    NowPeekU32 position_seq;
    NowPeekU32 button_generation;
    NowPeekU32 flags;
    NowPeekU32 arrival;
    NowPeekI32 h;
    NowPeekI32 v;

    if (self == NULL || !gButtonTaskRunning)
        return;
    cell = continuity_cell(self->table);
    if (cell == NULL) {
        gButtonTaskRunning = false;
        return;
    }
    ticks = (NowPeekU32)LMGetTicks();
    if (!cell->button_down) {
        if (!cell->pending_mouseup) {
            gButtonTaskRunning = false;
            return;
        }
        if ((NowPeekU32)(ticks - gReleaseSettleStarted)
                >= (NowPeekU32)kNowContinuityReleaseSettleMaxTicks) {
            /* Source/low memory only. Visibility is restored by the next
               task-time jGNE pass; a timer never calls QuickDraw. */
            now_ext_cursor_end_continuity_tracking();
            gButtonTaskRunning = false;
            return;
        }
        PrimeTime((QElemPtr)&gButtonTask.task,
                  (long)kNowPeekContinuityTickMs);
        return;
    }
    cell->button_timer_ticks++;
    if (native_input_sequence(cell) != gNativeInputBaseline) {
        release_button(cell, cell->button_generation,
                       (NowPeekU32)kNowPeekContinuityExitGuestInput);
        return;
    }

    before = cell->packet_seq;
    epoch = cell->packet_epoch;
    position_seq = cell->position_seq;
    h = cell->want_h;
    v = cell->want_v;
    button_generation = cell->button_generation;
    flags = cell->flags;
    arrival = cell->arrival_ticks;
    if (before != cell->packet_seq) {
        PrimeTime((QElemPtr)&gButtonTask.task,
                  (long)kNowPeekContinuityTickMs);
        return;
    }
    if (epoch != cell->epoch
            || !(flags & kNowPeekContinuityInside)) {
        release_button(cell, button_generation,
                       (NowPeekU32)kNowPeekContinuityExitHostLeft);
        return;
    }
    if ((NowPeekU32)(ticks - arrival)
            > now_continuity_clamp_lease(cell->lease_ticks)) {
        release_button(cell, button_generation,
                       (NowPeekU32)kNowPeekContinuityExitLeaseExpired);
        return;
    }
    if (now_continuity_sequence_newer(
            position_seq, cell->request_position_seq)) {
        Point pt;

        pt.h = (short)h;
        pt.v = (short)v;
        /* Tracking loops read MouseLocation while the PPC wire pump is
           starved. The final point remains requested below so task time can
           reconcile the drawn Cursor Device once the release unwinds it. */
        LMSetMouseLocation(pt);
        now_ext_cursor_remember_continuity_tracking_point(h, v);
        cell->request_h = h;
        cell->request_v = v;
        cell->request_position_seq = position_seq;
        cell->at_h = h;
        cell->at_v = v;
    }
    if ((cell->tracking_options
            & (NowPeekU32)kNowPeekContinuityTrackingPinHeldPoint) != 0
            && now_ext_cursor_reassert_continuity_tracking())
        cell->tracking_pin_writes++;
    if (now_continuity_button_action(
            cell->applied_button_generation, 1,
            button_generation, flags) == kNowContinuityButtonRelease) {
        release_button(cell, button_generation,
                       (NowPeekU32)kNowPeekContinuityExitNone);
        return;
    }
    PrimeTime((QElemPtr)&gButtonTask.task,
              (long)kNowPeekContinuityTickMs);
}

int now_ext_continuity_boot(NowPeekTable *table)
{
    NowPeekContinuityCell *cell;

    if (table == NULL || gInstalled)
        return 0;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                     + sizeof(NowPeekContinuityCell)))
        return 0;
    table->continuity_format =
        (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT;
    cell = &table->continuity;
    cell->state = (NowPeekU32)kNowPeekContinuityStateInactive;
    cell->exit_reason = (NowPeekU32)kNowPeekContinuityExitNone;
    if (!now_ext_continuity_safe_on_hardware()) {
        cell->state = (NowPeekU32)kNowPeekContinuityStateRefused;
        cell->exit_reason =
            (NowPeekU32)kNowPeekContinuityExitUnavailable;
        return 1;                    /* optional capability, valid absence */
    }
    if (!(table->caps & kNowPeekTableCapCursor)) {
        cell->state = (NowPeekU32)kNowPeekContinuityStateRefused;
        cell->exit_reason =
            (NowPeekU32)kNowPeekContinuityExitUnavailable;
        return 1;                    /* optional capability, valid absence */
    }
    gButtonTask.table = table;
    gButtonTask.task.tmAddr = (TimerUPP)now_ext_continuity_tm_entry;
    gButtonTask.task.tmWakeUp = 0;
    gButtonTask.task.tmReserved = 0;
    InsTime((QElemPtr)&gButtonTask.task);
    gButtonTaskInstalled = true;
    gTable = table;
    cell->service_proc = (NowPeekU32)now_ext_continuity_service;
    gInstalled = true;
    table->caps |= (NowPeekU32)kNowPeekTableCapContinuity;
    return 1;
}

void now_ext_continuity_rollback(NowPeekTable *table)
{
    now_ext_adb_observer_rollback(table);
    if (table != NULL && table->continuity.button_down)
        release_button_lowmem();
    gButtonTaskRunning = false;
    if (gButtonTaskInstalled) {
        RmvTime((QElemPtr)&gButtonTask.task);
        gButtonTaskInstalled = false;
    }
    gButtonTask.table = NULL;
    if (table != NULL
            && table->length
                >= (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                 + sizeof(NowPeekContinuityCell))) {
        memset(&table->continuity, 0, sizeof table->continuity);
        table->continuity_format = 0;
        table->caps &= ~(NowPeekU32)kNowPeekTableCapContinuity;
    }
    now_input_owner_release(kNowInputOwnerContinuity);
    gTable = NULL;
    gInstalled = false;
    gServiceActive = false;
    gPrimed = false;
    gNativeInputSeq = 0;
    gNativeInputBaseline = 0;
    gForcedResets = 0;
    gEventResetGeneration = 0;
    gTasktimeCursorApplies = 0;
    gReleaseSettleStarted = 0;
}
