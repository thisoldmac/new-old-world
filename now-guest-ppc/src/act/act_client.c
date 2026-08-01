#include "act_client.h"

#include <string.h>

#include "now_act_guard.h"
#include "peek.h"
#include "peek_oracle.h"

/* How long to wait for a target to pump. Ticks, so ~5 seconds - long
   enough for a busy application to reach its event loop, short enough
   that a suspended one says so instead of hanging the wire. */
#define kNowActDeadlineTicks 300UL

static NowPeekTable *act_table(void)
{
    /* now_peek_table() already gates on magic and an exact major; the
       plane's own gate is on top of that and is about LENGTH, which is
       the only thing that can tell a resident half that predates this
       plane from one that carries it. */
    return (NowPeekTable *)now_peek_table();
}

NowActStatus now_act_ready(void)
{
    NowPeekTable *table = act_table();

    switch (now_act_plane_state(table)) {
    case kNowActPlaneReady:
        break;
    case kNowActPlaneStale:
    case kNowActPlaneWrongFormat:
        return kNowActStaleExtension;
    case kNowActPlaneAbsent:
        return kNowActPlaneDark;
    default:
        return kNowActNoExtension;
    }
    /* The act plane needs the ANCHOR plane too: without it there is no
       A5 for any process and nothing can be addressed. Arming both is
       one word, and it is the application's word to write. */
    now_peek_arm((unsigned long)(kNowPeekCapAnchors | kNowPeekTableCapAct));
    return kNowActOk;
}

void now_act_shutdown(void)
{
    now_peek_disarm((unsigned long)kNowPeekTableCapAct);
}

NowPeekActCell *now_act_cell(void)
{
    NowPeekTable *table = act_table();

    if (now_act_plane_state(table) != kNowActPlaneReady) {
        return NULL;
    }
    return &table->act;
}

NowActStatus now_act_open(const ProcessSerialNumber *psn, NowActTarget *out)
{
    ProcessInfoRec      info;
    ProcessSerialNumber want;
    NowPeekAnchorMatch  match;
    NowPeekTable       *table = act_table();

    if (out == NULL) {
        return kNowActNoTarget;
    }
    memset(out, 0, sizeof *out);

    if (psn != NULL) {
        want = *psn;
    } else if (GetFrontProcess(&want) != noErr) {
        return kNowActNoTarget;
    }
    out->psn = want;

    if (now_ax_bind_process(&want, &out->ax) != kNowPeekReadOk) {
        return kNowActNoTarget;
    }

    /* The A5 world, from the anchor plane's own oracle.
       now_ax_bind_process resolves the same match internally but does
       not publish A5, and its header is not this thread's to change, so
       the oracle is asked again here rather than a second answer being
       invented. Two GetProcessInformation calls; one source of truth. */
    memset(&info, 0, sizeof info);
    info.processInfoLength = (long)sizeof info;
    out->name[0] = 0;
    info.processName = out->name;
    if (GetProcessInformation(&want, &info) != noErr) {
        return kNowActNoTarget;
    }
    if (now_peek_anchor_match(table, (unsigned long)info.processLocation,
                              (unsigned long)info.processSize, out->name,
                              (NowPeekU32)TickCount(), 0, &match)
        != kNowPeekAnchorOk) {
        return kNowActNoAnchor;
    }
    out->a5 = (unsigned long)match.a5;
    if (out->a5 == 0) {
        return kNowActNoAnchor;
    }
    return kNowActOk;
}

/* Give up the processor without dequeuing anything. Mask zero: we want
   the scheduler, not the events. */
static void act_yield(void)
{
    EventRecord ev;

    (void)WaitNextEvent(0, &ev, 2L, NULL);
}

/* Copy the cell out under the seqlock: retry while the writer is
   mid-update, and take the copy that brackets an even, unchanged seq. */
static void act_snapshot(const NowPeekActCell *cell, NowPeekActCell *out)
{
    int i;

    for (i = 0; i < 8; i++) {
        NowPeekU32 before = cell->seq;

        if ((before & 1UL) != 0) {
            continue;
        }
        BlockMoveData((Ptr)cell, (Ptr)out, (Size)sizeof *out);
        if (cell->seq == before) {
            return;
        }
    }
    /* Eight torn reads in a row means the filter is writing far more
       often than we are reading, which cannot happen for a
       single-consumer channel - take the last copy and let the status
       field speak for itself rather than looping forever. */
}

NowActStatus now_act_submit(unsigned long target_a5, NowPeekActCell *snapshot)
{
    NowPeekActCell *cell = now_act_cell();
    unsigned long   deadline;

    if (cell == NULL) {
        return kNowActNoExtension;
    }
    cell->target_a5 = (NowPeekU32)target_a5;
    cell->error = kNowPeekActErrNone;
    cell->fired = 0;
    cell->armed = kNowPeekActArmNone;
    cell->find_window_fired = 0;
    cell->fw_answers = 0;
    /* Zero the per-request counters, never the global ones: these
       describe THIS request and would otherwise carry the last one's
       answer in. */
    cell->trap_hits_target[0] = 0;
    cell->trap_hits_target[1] = 0;
    cell->trap_hits_target[2] = 0;
    cell->trap_hits_target[3] = 0;
    cell->status = kNowPeekActStatusPending;   /* the commit, written last */

    deadline = (unsigned long)TickCount() + kNowActDeadlineTicks;
    while (cell->status == kNowPeekActStatusPending
           && (unsigned long)TickCount() < deadline) {
        act_yield();
    }
    if (cell->status == kNowPeekActStatusPending) {
        now_act_withdraw();
        return kNowActTimeout;
    }
    act_snapshot(cell, snapshot);
    if (snapshot->status != kNowPeekActStatusDone) {
        now_act_withdraw();
        return kNowActRefused;
    }
    return kNowActOk;
}

NowActStatus now_act_await_fired(NowPeekActCell *snapshot)
{
    NowPeekActCell *cell = now_act_cell();
    unsigned long   deadline;

    if (cell == NULL) {
        return kNowActNoExtension;
    }
    deadline = (unsigned long)TickCount() + kNowActDeadlineTicks;
    while (!cell->fired && (unsigned long)TickCount() < deadline) {
        act_yield();
    }
    act_snapshot(cell, snapshot);
    if (!snapshot->fired) {
        now_act_withdraw();
        return kNowActNotTaken;
    }
    now_act_withdraw();
    return kNowActOk;
}

void now_act_withdraw(void)
{
    NowPeekActCell *cell = now_act_cell();

    if (cell == NULL) {
        return;
    }
    cell->armed = kNowPeekActArmNone;
    cell->status = kNowPeekActStatusIdle;
}

const char *now_act_error_code(unsigned long plane_error)
{
    switch (plane_error) {
    case kNowPeekActErrNone:        return "none";
    case kNowPeekActErrBadOp:       return "bad-request";
    case kNowPeekActErrNoPatch:     return "act-no-patch";
    case kNowPeekActErrBadWindowOp: return "bad-request";
    case kNowPeekActErrNoWindow:    return "element-not-found";
    case kNowPeekActErrAbi:         return "act-abi";
    case kNowPeekActErrNotOurWindow: return "element-not-found";
    case kNowPeekActErrNotDialog:   return "not-a-dialog";
    case kNowPeekActErrNoItem:      return "element-not-found";
    case kNowPeekActErrBadTe:       return "bad-handle";
    case kNowPeekActErrTextKind:    return "bad-request";
    case kNowPeekActErrNotText:     return "not-text";
    default:                        return "act-refused";
    }
}

const char *now_act_error_message(unsigned long plane_error)
{
    switch (plane_error) {
    case kNowPeekActErrNone:
        return "no error";
    case kNowPeekActErrBadOp:
        return "the resident act plane does not know that operation";
    case kNowPeekActErrNoPatch:
        return "the trap patch that operation needs was never installed";
    case kNowPeekActErrBadWindowOp:
        return "that is not one of move, resize, zoom or close";
    case kNowPeekActErrNoWindow:
        return "the request named no window";
    case kNowPeekActErrAbi:
        return "the patch answered and the caller read something else - "
               "the trap calling convention is wrong in this build";
    case kNowPeekActErrNotOurWindow:
        return "that window is not in the target process's own window "
               "list, so nothing was read and nothing was written";
    case kNowPeekActErrNotDialog:
        return "that window is not a dialog, so it has no item list";
    case kNowPeekActErrNoItem:
        return "no such item in that dialog";
    case kNowPeekActErrBadTe:
        return "the text handle is empty, outside the application's heap, "
               "or belongs to a different window";
    case kNowPeekActErrTextKind:
        return "unknown text kind";
    case kNowPeekActErrNotText:
        return "that dialog item is not an editable or static text item";
    default:
        return "the target refused the request";
    }
}

const char *now_act_status_code(NowActStatus status)
{
    switch (status) {
    case kNowActOk:              return "ok";
    case kNowActNoExtension:     return "act-plane-absent";
    case kNowActStaleExtension:  return "act-plane-stale";
    case kNowActPlaneDark:       return "act-plane-absent";
    case kNowActNoTarget:        return "no-such-process";
    case kNowActNoAnchor:        return "act-no-anchor";
    case kNowActTimeout:         return "act-timeout";
    case kNowActNotArmed:        return "act-not-armed";
    case kNowActNotTaken:        return "act-not-taken";
    case kNowActRefused:         return "act-refused";
    default:                     return "act-refused";
    }
}

const char *now_act_status_message(NowActStatus status)
{
    switch (status) {
    case kNowActOk:
        return "served";
    case kNowActNoExtension:
        return "the NOW Extension is not installed on this Mac, so no "
               "application can be driven from a scene";
    case kNowActStaleExtension:
        return "the installed NOW Extension predates the act plane - it "
               "has no room for a request, so nothing was written into "
               "it. Reinstall the extension and restart this Mac";
    case kNowActPlaneDark:
        return "the installed NOW Extension does not carry the act plane";
    case kNowActNoTarget:
        return "no such process on this Mac, or its partition could not "
               "be read";
    case kNowActNoAnchor:
        return "that process has not pumped its event loop since the "
               "plane was armed, so nothing knows which A5 world it is";
    case kNowActTimeout:
        return "the target did not serve the request - it is not pumping "
               "its event loop, or it is suspended";
    case kNowActNotArmed:
        return "the target served the request and did not arm";
    case kNowActNotTaken:
        return "the click went and the application never called the trap "
               "that goes with it";
    case kNowActRefused:
        return "the target refused the request";
    default:
        return "the target refused the request";
    }
}
