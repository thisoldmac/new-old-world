/* P9 Continuity vehicle. Network parsing and scheduling belong to the PPC
   application. Its cooperative wire pump enters now_ext_continuity_service
   through Mixed Mode; this resident consumes one preallocated latest-state
   cell, publishes one requested point, and commits only the result returned by
   the PPC application's Apple CursorDevicesGlue call. */
#include <LowMem.h>
#include <MacTypes.h>

#include <string.h>

#include "peek_table.h"
#include "now_continuity_logic.h"
#include "now_ext_core_logic.h"
#include "now_ext_cursor_input.h"
#include "now_input_owner.h"

static NowPeekTable *gTable;
static Boolean gInstalled;
static volatile Boolean gServiceActive;
static volatile Boolean gPrimed;
static volatile NowPeekU32 gNativeInputSeq;
static volatile NowPeekU32 gNativeInputBaseline;

/* v0 is movement only. These legacy counters stay in the accretive table and
   therefore remain zero; clicks and their Event Manager vehicle belong to
   v0.5a rather than being smuggled into the movement resident. */
static volatile NowPeekU32 gForcedResets;
static volatile NowPeekU32 gEventResetGeneration;
static volatile NowPeekU32 gTasktimeCursorApplies;

static NowPeekContinuityCell *continuity_cell(NowPeekTable *table)
{
    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic)
        return NULL;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                     + sizeof(NowPeekContinuityCell)))
        return NULL;
    if (table->continuity_format
            != (NowPeekU32)kNowPeekContinuityFormatV3)
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
    cell->event_down_posts = 0;
    cell->event_up_posts = 0;
    cell->event_post_failures = 0;
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

static void force_reset(NowPeekContinuityCell *cell)
{
    /* There is no button or global cursor-manager debt in v0. Revocation is
       therefore bounded resident state only and cannot depend on Event
       Manager, QuickDraw, or the foreground application's next event pass. */
    cell->button_down = 0;
    gForcedResets++;
    gEventResetGeneration++;
}

static void finish_locked(NowPeekContinuityCell *cell, NowPeekU32 reason,
                          NowPeekU32 ticks)
{
    force_reset(cell);
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
    /* A new epoch is a release boundary even if the application failed to
       disarm the preceding one. Reset first, then publish the new authority. */
    force_reset(cell);
    cell->state = (NowPeekU32)kNowPeekContinuityStateArmed;
    cell->exit_reason = (NowPeekU32)kNowPeekContinuityExitNone;
    cell->accepted_hz = now_continuity_accept_rate(cell->requested_hz);
    cell->last_arrival_ticks = ticks;
    cell->observed_packet_seq = cell->packet_seq;
    cell->applied_position_seq = 0;
    cell->request_position_seq = 0;
    cell->applied_button_generation = 0;
    gNativeInputSeq = now_ext_cursor_physical_input_seq();
    gNativeInputBaseline = gNativeInputSeq;
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

    /* Authority/reset wins over every stale datagram. The application calls
       this immediately after arm/disarm/disconnect as well as from every
       ordinary and nested wire pump. v0 holds no button, so a starved app has
       no interrupt-time state that must be released behind its back. */
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
        gTasktimeCursorApplies++;
        cell->at_h = cell->request_h;
        cell->at_v = cell->request_v;
        cell->applied_position_seq = cell->apply_result_seq;
        cell->apply_ticks = ticks;
        trace_event(cell, (NowPeekU32)kNowPeekContinuityTraceApplied,
                    ticks, (NowPeekI32)cell->applied_position_seq,
                    cell->at_h);
    }

    /* Sample physical RawMouse before the owned synthetic device reports its
       next point. Recent owned reports are excluded by the sampler, while a
       real ADB/USB change exits before another host point is applied. */
    native_input_seq = now_ext_cursor_physical_input_seq();
    gNativeInputSeq = native_input_seq;
    if (native_input_seq != gNativeInputBaseline) {
        gNativeInputBaseline = native_input_seq;
        finish_locked(cell,
                      (NowPeekU32)kNowPeekContinuityExitGuestInput, ticks);
        service_return(cell);
        return;
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
                cell->request_h = h;
                cell->request_v = v;
                cell->request_position_seq = position_seq;
                trace_event(cell,
                            (NowPeekU32)kNowPeekContinuityTraceRequest,
                            ticks, (NowPeekI32)position_seq, h);
            }
        }
    }
    publish_tasktime_counters(cell);
    service_return(cell);
}

int now_ext_continuity_boot(NowPeekTable *table)
{
    NowPeekContinuityCell *cell;

    if (table == NULL || gInstalled)
        return 0;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                     + sizeof(NowPeekContinuityCell)))
        return 0;
    table->continuity_format = (NowPeekU32)kNowPeekContinuityFormatV3;
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
    gTable = table;
    cell->service_proc = (NowPeekU32)now_ext_continuity_service;
    gInstalled = true;
    table->caps |= (NowPeekU32)kNowPeekTableCapContinuity;
    return 1;
}

void now_ext_continuity_rollback(NowPeekTable *table)
{
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
}
