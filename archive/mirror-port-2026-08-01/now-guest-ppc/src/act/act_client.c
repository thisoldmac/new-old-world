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

/* now_ax_bind_process's five verdicts (axprocess.h), each its own
   NowActStatus rather than one shared "no-such-process".
   observe.c:bind_status() makes the identical translation for the same
   reason, into the same five words ("no-plane", "no-anchor",
   "ambiguous", "mismatch", "unreadable" - see contract/asyncapi.yaml's
   `bind` field on `observe`/`axsnap`): one plane, one vocabulary, so a
   caller reading either surface's failure meets the same five words for
   the same five facts about the machine.

   kNowPeekReadOk is not a case here on purpose - a caller checks that
   before asking this function anything, the same way bind_status()'s
   caller does. */
static NowActStatus now_act_bind_status(NowPeekReadStatus status)
{
    switch (status) {
    case kNowPeekReadNoPlane:    return kNowActNoPlane;
    case kNowPeekReadNoAnchor:   return kNowActNoAnchor;
    case kNowPeekReadAmbiguous:  return kNowActAmbiguous;
    case kNowPeekReadMismatch:   return kNowActMismatch;
    case kNowPeekReadUnreadable: return kNowActUnreadable;
    case kNowPeekReadOk:
    case kNowPeekReadNoWindows:
    case kNowPeekReadStub:
    default:
        break;
    }
    /* Neither of the two default cases above is a real answer
       now_ax_bind_process gives (see axprocess.c: it returns only the
       five above, or Ok) - this is the same fallback observe.c's
       bind_status() takes for the same unreachable default, not a sixth
       verdict. */
    return kNowActUnreadable;
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
    NowPeekReadStatus   bind_st;

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

    /* CHANGED 2026-08-01: this used to test only `!= kNowPeekReadOk` and
       answer kNowActNoTarget for every one of the five ways a bind can
       fail - so a Finder that had simply not pumped since the plane
       armed (NoAnchor) read on the wire exactly like a process that does
       not exist, and so did the two recycled-slot verdicts (Ambiguous,
       Mismatch) an ABI defect would also produce. now_act_bind_status
       keeps the verdict now_ax_bind_process already computed instead of
       discarding it. */
    bind_st = now_ax_bind_process(&want, &out->ax);
    if (bind_st != kNowPeekReadOk) {
        return now_act_bind_status(bind_st);
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
   the scheduler, not the events.
 *
 * AND IT DOES NOT REACH THE RESIDENT HOOK, which is worth knowing here
 * because the obvious repair for the act plane depends on it. Measured
 * 2026-08-01 on mac99, three times: while this loop runs, every act pass
 * the extension makes is in the TARGET's A5 world - 293 to 303 of them
 * in five seconds, and not one in ours. Changing the mask does not fix
 * it: networkMask (nonzero, matches nothing) and everyEvent (what this
 * application's own main loop uses) both measured the same 0 passes in
 * our world. A background Carbon application's WaitNextEvent does not
 * fall through to the classic Event Manager's GetNextEvent, so the jGNE
 * filter never runs for it, whatever it asks for. The mask is back to
 * zero because zero is the honest thing for a yield that must not take
 * an event, and because none of the alternatives bought anything. */
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

/* The world the request in flight is addressed to. Single-flight by the
   cell's own design, so one word is the whole state. */
static unsigned long g_target_a5;

/* What the last click ask saw, for the failure message. Read only after
   now_act_post_click returns. */
static unsigned long g_click_passes;
static unsigned long g_click_last_a5;

unsigned long now_act_click_passes(void) { return g_click_passes; }
unsigned long now_act_click_last_a5(void) { return g_click_last_a5; }

NowActStatus now_act_submit(unsigned long target_a5, NowPeekActCell *snapshot)
{
    NowPeekActCell *cell = now_act_cell();
    unsigned long   deadline;

    if (cell == NULL) {
        return kNowActNoExtension;
    }
    g_target_a5 = target_a5;
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

NowActStatus now_act_post_click(void)
{
    NowPeekActCell *cell = now_act_cell();
    unsigned long   deadline;

    if (cell == NULL) {
        return kNowActNoExtension;
    }
    cell->click_posted = 0;
    cell->click_passes = 0;
    cell->click_last_a5 = 0;
    /* NOBODY is excluded, and the two attempts that excluded somebody are
       why. Naming this application's own world measured 0/6 with the ask
       never served; naming the target's - so any other process would do
       it - measured 0/5 with 300 passes in five seconds and every one of
       them in the target's world. On this machine, while the wire waits,
       the target is the ONLY process whose event loop reaches the
       resident hook, so "post it from somewhere else" is not a mechanism
       that exists here however it is spelled.
       What is still different from the arming pass, and is the whole
       remaining point of routing the press through this flag at all, is
       WHEN: the ask is written after now_act_submit has seen the arm
       published, so the press is queued on a LATER pass than the one
       that armed - after the target's GetNextEvent has returned and the
       application has run its own code. That is upstream's ordering, and
       it is the one part of it this port never reproduced. */
    /* NOBODY is excluded: the next pass posts it, whoever it belongs to.
       Three exclusions were measured and all three are dead ends, which
       is why this is spelled as "nobody" rather than left looking like
       an oversight - see act_client.h. */
    cell->click_not_a5 = 0;
    cell->click_pending = 1;            /* the ask, written last */

    deadline = (unsigned long)TickCount() + kNowActDeadlineTicks;
    while (cell->click_pending != 0
           && (unsigned long)TickCount() < deadline) {
        act_yield();
    }
    if (cell->click_pending != 0) {
        cell->click_pending = 0;
        g_click_passes = cell->click_passes;
        g_click_last_a5 = cell->click_last_a5;
        return kNowActClickNoPass;
    }
    g_click_passes = cell->click_passes;
    g_click_last_a5 = cell->click_last_a5;
    if (cell->click_posted == 0) {
        return kNowActClickRefused;
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
    /* And the click, for the same reason: an ask left standing is a
       press this application would queue on some later pass, for a
       request that is already over. */
    cell->click_pending = 0;
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
    case kNowActNoPlane:         return "act-no-plane";
    case kNowActAmbiguous:       return "act-ambiguous";
    case kNowActMismatch:        return "act-mismatch";
    case kNowActUnreadable:      return "act-unreadable";
    case kNowActTimeout:         return "act-timeout";
    case kNowActNotArmed:        return "act-not-armed";
    case kNowActNotTaken:        return "act-not-taken";
    case kNowActClickNoPass:     return "act-click-no-pass";
    case kNowActClickRefused:    return "act-click-refused";
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
        return "no process on this Mac answers to that serial number";
    case kNowActNoAnchor:
        return "that process has not pumped its event loop since the "
               "plane was armed, so nothing knows which A5 world it is";
    case kNowActNoPlane:
        return "the anchor plane is not armed, so no process can be "
               "bound to an A5 world at all";
    case kNowActAmbiguous:
        return "two anchor slots claim that process's partition, and "
               "nothing distinguishes them - refused rather than guessed";
    case kNowActMismatch:
        return "an anchor claims that partition, but its A5 and its "
               "stack base describe different address spaces - a "
               "recycled slot wearing a dead application's anchor, not "
               "this one";
    case kNowActUnreadable:
        return "that process is bound, but its window or menu list "
               "pointer fails validation against both its own partition "
               "and the system heap - the walk found debris, not an A5 "
               "world";
    case kNowActTimeout:
        return "the target did not serve the request - it is not pumping "
               "its event loop, or it is suspended";
    case kNowActNotArmed:
        return "the target served the request and did not arm";
    case kNowActNotTaken:
        return "the click went and the application never called the trap "
               "that goes with it";
    case kNowActClickNoPass:
        return "the target armed and no process but the target itself "
               "reached the resident half while the press was waiting to "
               "be queued";
    case kNowActClickRefused:
        return "the target armed and this Mac's event queue refused the "
               "press";
    case kNowActRefused:
        return "the target refused the request";
    default:
        return "the target refused the request";
    }
}
