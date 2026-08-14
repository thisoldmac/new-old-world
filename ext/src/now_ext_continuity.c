/* P9 Continuity vehicle. Network parsing and scheduling belong to the PPC
   application. Its cooperative wire pump enters now_ext_continuity_service
   through Mixed Mode; this resident consumes one preallocated latest-state
   cell, publishes one requested point, and commits only the result returned by
   the PPC application's Apple CursorDevicesGlue call. */
#include <LowMem.h>
#include <MacTypes.h>
#include <Events.h>
#include <Timer.h>

#include <string.h>

#include "peek_table.h"
#include "now_continuity_logic.h"
#include "now_ext_core_logic.h"
#include "now_ext_adb_observer.h"
#include "now_ext_continuity_keyboard.h"
#include "now_ext_continuity_trace.h"
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
/* One press may wait behind the manager-up that precedes it in a v4 UDP
   packet. A second distinct deferred press is a protocol overflow and is
   counted rather than silently replacing the first. */
static volatile NowPeekU32 gDeferredPressGeneration;

typedef struct {
    TMTask task;                /* first: the Time Manager owns this */
    NowPeekTable *table;
} ContinuityButtonTask;

/* CurApName (Str31, 0x0910), reached through a VOLATILE POINTER VARIABLE
   for the same reason now_ext_cursor.c reaches CrsrNew that way: GCC folds
   a dereference of a constant tiny address and refuses it under
   -Werror=array-bounds as "likely at address zero". */
static volatile unsigned char *volatile gCurApName =
    (volatile unsigned char *)0x0910UL;

static ContinuityButtonTask gButtonTask;
static Boolean gButtonTaskInstalled;
static volatile Boolean gButtonTaskRunning;
static volatile NowPeekU32 gReleaseSettleStarted;
/* The human's own DoubleTime, held only while an epoch runs with the wide
   window option. Valid-flag first: an exit path may run more than once and
   a second restore must be a no-op, not a restore of our own wide value. */
static NowPeekU32 gSavedDoubleTime;
static volatile Boolean gSavedDoubleTimeValid;

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

static NowPeekI32 pack_point(NowPeekI32 h, NowPeekI32 v)
{
    return (NowPeekI32)((((NowPeekU32)h & 0xFFFFu) << 16)
        | ((NowPeekU32)v & 0xFFFFu));
}

void now_ext_continuity_trace_tracking_conflict(
    NowPeekI32 live_h, NowPeekI32 live_v,
    NowPeekI32 source_h, NowPeekI32 source_v)
{
    NowPeekContinuityCell *cell = continuity_cell(gTable);

    if (cell == NULL || !cell->enabled)
        return;
    trace_event(cell,
                (NowPeekU32)kNowPeekContinuityTraceTrackingConflict,
                (NowPeekU32)TickCount(), pack_point(live_h, live_v),
                pack_point(source_h, source_v));
}

void now_ext_continuity_trace_keyboard_result(
    NowPeekU32 generation, NowPeekU32 action, NowPeekU32 error)
{
    NowPeekContinuityCell *cell = continuity_cell(gTable);
    NowPeekI32 packed;

    if (cell == NULL || !cell->enabled)
        return;
    packed = (NowPeekI32)(((action & 0xFFFFu) << 16)
                          | (error & 0xFFFFu));
    trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceKeyboardResult,
                (NowPeekU32)TickCount(), (NowPeekI32)generation, packed);
}

void now_ext_continuity_trace_idle_settle(
    NowPeekU32 count, NowPeekU32 position_seq)
{
    NowPeekContinuityCell *cell = continuity_cell(gTable);

    if (cell == NULL || !cell->enabled)
        return;
    trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceIdleSettle,
                (NowPeekU32)TickCount(), (NowPeekI32)count,
                (NowPeekI32)position_seq);
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

/* DoubleTime is borrowed, never owned: every epoch exit - normal, forced,
   or plane rollback - puts the human's saved value back. This is one
   low-memory word write, so any exit context including the Time Manager
   task may call it, and calling it twice is harmless. */
static void restore_double_time(void)
{
    if (!gSavedDoubleTimeValid)
        return;
    gSavedDoubleTimeValid = false;
    LMSetDoubleTime((UInt32)gSavedDoubleTime);
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
    cell->event_request_arrival_ticks = cell->last_arrival_ticks;
    cell->event_request_exposure_ticks = (NowPeekU32)LMGetTicks();
    cell->event_request_generation = generation; /* commit last */
}

/* Capture the Event Manager's synthetic mouse record in the same guest clock
   domain as arrival, exposure and manager apply. The first unmatched edge of
   the same direction owns the observation; actual event coordinates are kept
   so that this diagnostic never assumes they equal the requested point. */
void now_ext_continuity_observe_event(EventRecord *event, NowPeekU32 ticks)
{
    NowPeekContinuityCell *cell = continuity_cell(gTable);
    NowPeekU32 down;
    NowPeekU32 count;
    NowPeekU32 index;

    if (cell == NULL || event == NULL || !cell->enabled)
        return;
    if (event->what == mouseDown)
        down = 1;
    else if (event->what == mouseUp)
        down = 0;
    else
        return;
    count = cell->event_timing_count;
    if (count > (NowPeekU32)kNowPeekContinuityEventTimingCapacity)
        count = (NowPeekU32)kNowPeekContinuityEventTimingCapacity;
    for (index = 0; index < count; index++) {
        NowPeekContinuityEventTiming *entry = &cell->event_timing[index];
        NowPeekU32 before = entry->write_seq;
        NowPeekU32 observer;

        if ((before & 1u) != 0 || entry->down != down
                || entry->event_observed_ticks != 0)
            continue;
        entry->write_seq = before + 1u;
        entry->event_when = (NowPeekU32)event->when;
        entry->event_observed_ticks = ticks;
        entry->event_h = (NowPeekI32)event->where.h;
        entry->event_v = (NowPeekI32)event->where.v;
        entry->write_seq = before + 2u;
        /* Every other stage of the chain is recorded; WHICH PROCESS
           dequeued the event is not, and misrouting is indistinguishable
           from non-recognition without it. jGNE runs in the dequeuing
           process, so CurApName here names it. */
        observer = ((NowPeekU32)gCurApName[1] << 24)
            | ((NowPeekU32)gCurApName[2] << 16)
            | ((NowPeekU32)gCurApName[3] << 8)
            | (NowPeekU32)gCurApName[4];
        trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceEventObserved,
                    ticks,
                    (NowPeekI32)((down << 16)
                                 | ((NowPeekU32)event->when & 0xFFFFu)),
                    (NowPeekI32)observer);
        return;
    }
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
        /* Every forced reason ends the epoch, and a timer-forced end may
           never reach finish_locked if the application stays starved. */
        restore_double_time();
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
        if (cell->event_result_err == noErr
                && gDeferredPressGeneration != 0) {
            NowPeekU32 deferred = gDeferredPressGeneration;
            gDeferredPressGeneration = 0;
            request_button(cell, deferred, 1);
        }
        return cell->event_result_err == noErr;
    }
    return 0;
}

static void force_reset(NowPeekContinuityCell *cell, NowPeekU32 reason)
{
    gDeferredPressGeneration = 0;
    release_button(cell, cell->button_generation, reason);
    gForcedResets++;
    gEventResetGeneration++;
}

static void finish_locked(NowPeekContinuityCell *cell, NowPeekU32 reason,
                          NowPeekU32 ticks)
{
    force_reset(cell, reason);
    restore_double_time();
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
    cell->event_request_arrival_ticks = 0;
    cell->event_request_exposure_ticks = 0;
    cell->event_timing_count = 0;
    cell->event_timing_dropped = 0;
    cell->pending_mouseup = 0;
    cell->button_release_reason = 0;
    /* Report the human's own window even if a prior epoch's wide value is
       somehow still installed; the saved copy is the honest reading. */
    cell->double_time_ticks = gSavedDoubleTimeValid
        ? gSavedDoubleTime : (NowPeekU32)LMGetDoubleTime();
    if ((cell->tracking_options
            & (NowPeekU32)kNowPeekContinuityTrackingWideDoubleTime) != 0
            && !gSavedDoubleTimeValid) {
        gSavedDoubleTime = cell->double_time_ticks;
        gSavedDoubleTimeValid = true;
        LMSetDoubleTime((UInt32)kNowPeekContinuityWideDoubleTimeTicks);
    }
    gDeferredPressGeneration = 0;
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

static void apply_button_edge(NowPeekContinuityCell *cell,
                              NowPeekU32 generation, NowPeekU32 flags)
{
    switch (now_continuity_button_action(
                cell->applied_button_generation,
                cell->button_down != 0, generation, flags)) {
        case kNowContinuityButtonPress:
            if (cell->pending_mouseup) {
                if (gDeferredPressGeneration == 0) {
                    gDeferredPressGeneration = generation;
                    cell->button_edge_deferrals++;
                } else if (gDeferredPressGeneration != generation) {
                    cell->button_edge_overflows++;
                }
            } else {
                request_button(cell, generation, 1);
            }
            break;
        case kNowContinuityButtonRelease:
            release_button(cell, generation,
                           (NowPeekU32)kNowPeekContinuityExitNone);
            break;
        default:
            break;
    }
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
    NowPeekU32 button_generation;
    NowPeekU32 previous_button_generation;
    NowPeekU32 previous_button_flags;
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
    /* Admit a coherent packet before evaluating its lease. The Open Transport
       notifier can publish a keepalive while the application is starved in a
       nested Toolbox loop; when cooperative service resumes, comparing ticks
       with the PREVIOUS admitted arrival first expires a lease that is already
       renewed in this cell. Stale epochs still cannot renew it, and host-left
       remains authoritative over the timeout. */
    before = cell->packet_seq;
    if (before != cell->observed_packet_seq) {
        packet_epoch = cell->packet_epoch;
        position_seq = cell->position_seq;
        h = cell->want_h;
        v = cell->want_v;
        flags = cell->flags;
        button_generation = cell->button_generation;
        previous_button_generation = cell->previous_button_generation;
        previous_button_flags = cell->previous_button_flags;
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
            /* History is older by construction and therefore applies first.
               If it releases a held first click, the current second-click
               press waits behind that manager-up without being discarded. */
            apply_button_edge(cell, previous_button_generation,
                              previous_button_flags);
            apply_button_edge(cell, button_generation, flags);
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
    NowPeekU32 previous_button_generation;
    NowPeekU32 previous_button_flags;
    NowPeekU32 release_generation;
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
    previous_button_generation = cell->previous_button_generation;
    previous_button_flags = cell->previous_button_flags;
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
    /* An up in EITHER edge slot must reach MBState from here. Under rapid
       clicking the current edge is already the next press by the time this
       timer looks, and the release it needs is in the previous slot -
       which only task time applied, while the press's own target starved
       task time (302 ticks, epoch 11, 2026-08-13 185037). The press that
       follows stays pending for the service's ordered task-time apply. */
    release_generation = now_continuity_release_due(
        cell->applied_button_generation, 1,
        previous_button_generation, previous_button_flags,
        button_generation, flags);
    if (release_generation != 0) {
        release_button(cell, release_generation,
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
    restore_double_time();
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
    gDeferredPressGeneration = 0;
    gReleaseSettleStarted = 0;
}
