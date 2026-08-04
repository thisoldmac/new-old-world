#include "act_client.h"

#include <string.h>

#include "now_act_guard.h"
#include "peek.h"
#include "peek_oracle.h"

/* How long to wait for a target to pump. Ticks, so ~5 seconds - long
   enough for a busy application to reach its event loop, short enough
   that a suspended one says so instead of hanging the wire. */
#define kNowActDeadlineTicks 300UL

static NowPeekU32 g_act_generation;
static NowPeekU32 g_scene_generation;
static NowActSettlementStore g_settlements;
static NowPeekU32 g_last_correlation_hi;
static NowPeekU32 g_last_correlation_lo;
static int g_last_correlation_valid;

static NowPeekTable *act_table(void);

void now_act_begin_command(void)
{
    g_last_correlation_valid = 0;
}

void now_act_note_scene_generation(unsigned long generation)
{
    g_scene_generation = (NowPeekU32)generation;
}

void now_act_observe_scene(const NowScene *scene)
{
    NowPeekTable *table = act_table();
    NowPeekU32 epoch = table != NULL ? table->writer.owner_epoch : 0;
    if (table != NULL
        && table->act_v2.resident_request_generation
             == table->act_v2.request_generation
        && table->act_v2.resident_correlation_hi
             == table->act_v2.correlation_hi
        && table->act_v2.resident_correlation_lo
             == table->act_v2.correlation_lo) {
        now_act_settlement_note_resident(
            &g_settlements, table->act_v2.resident_correlation_hi,
            table->act_v2.resident_correlation_lo,
            table->act_v2.resident_stage);
    }
    now_act_settlement_observe_scene(&g_settlements, scene, epoch);
}

const NowActSettlementRecord *now_act_last_settlement(void)
{
    if (!g_last_correlation_valid) return NULL;
    return now_act_settlement_find(&g_settlements, g_last_correlation_hi,
                                   g_last_correlation_lo);
}

long now_act_encode_settlements(char *out, long cap)
{
    return now_act_settlement_encode(&g_settlements, out, cap);
}

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
    now_peek_claim(kNowPeekOwnerAct,
                   (unsigned long)(kNowPeekCapAnchors
                                   | kNowPeekTableCapAct));
    return kNowActOk;
}

void now_act_shutdown(void)
{
    now_peek_release(kNowPeekOwnerAct,
                     (unsigned long)(kNowPeekCapAnchors
                                     | kNowPeekTableCapAct));
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

static void act_v2_describe(NowPeekTable *table, const NowActTarget *target,
                            unsigned long deadline)
{
    NowPeekActCell *cell = &table->act;
    NowPeekActV2Cell *v2 = &table->act_v2;
    NowPeekU32 generation = ++g_act_generation;
    NowActSettlementSpec spec;

    if (generation == 0) generation = ++g_act_generation;
    v2->correlation_hi = table->writer.session_nonce_lo;
    v2->correlation_lo = generation;
    v2->writer_epoch = table->writer.owner_epoch;
    v2->target_a5 = (NowPeekU32)target->a5;
    v2->target_psn_high = (NowPeekU32)target->psn.highLongOfPSN;
    v2->target_psn_low = (NowPeekU32)target->psn.lowLongOfPSN;
    v2->scene_generation = g_scene_generation;
    v2->operation_code = cell->op;
    v2->operation_object = 0;
    v2->operation_aux = 0;
    switch (cell->op) {
    case kNowPeekActOpMenu:
        v2->operation_kind = kNowPeekActKindMenu;
        v2->operation_object = ((NowPeekU32)cell->menu_id & 0xFFFFUL) << 16;
        v2->operation_object |= (NowPeekU32)cell->item_index & 0xFFFFUL;
        break;
    case kNowPeekActOpControl:
        v2->operation_kind = kNowPeekActKindControl;
        v2->operation_object = cell->control_handle;
        v2->operation_aux = cell->part_code;
        break;
    case kNowPeekActOpWindow:
        v2->operation_kind = kNowPeekActKindWindow;
        v2->operation_object = cell->window_ptr;
        v2->operation_aux = cell->window_op;
        break;
    case kNowPeekActOpTextGet:
    case kNowPeekActOpTextSet:
        v2->operation_kind = kNowPeekActKindText;
        v2->operation_object = cell->text_handle != 0
                             ? cell->text_handle : cell->text_window;
        v2->operation_aux = cell->text_kind;
        break;
    case kNowPeekActOpDialogItem:
        v2->operation_kind = kNowPeekActKindDialogItem;
        v2->operation_object = cell->control_handle;
        v2->operation_aux = cell->text_item;
        break;
    case kNowPeekActOpVisibility:
        v2->operation_kind = kNowPeekActKindVisibility;
        v2->operation_object = (NowPeekU32)cell->item_index;
        break;
    default:
        v2->operation_kind = kNowPeekActKindNone;
        break;
    }
    v2->deadline_ticks = (NowPeekU32)deadline;
    v2->request_generation = generation; /* publish last */

    now_act_settlement_change_session(&g_settlements,
                                      table->writer.owner_epoch,
                                      (NowPeekU32)TickCount());
    memset(&spec, 0, sizeof spec);
    spec.correlation_hi = v2->correlation_hi;
    spec.correlation_lo = v2->correlation_lo;
    spec.writer_epoch = v2->writer_epoch;
    spec.target_psn_high = v2->target_psn_high;
    spec.target_psn_low = v2->target_psn_low;
    spec.request_scene = v2->scene_generation;
    spec.kind = v2->operation_kind;
    spec.operation = v2->operation_code;
    spec.object = v2->operation_object;
    spec.post_object = v2->operation_object;
    spec.aux = v2->operation_aux;
    if (cell->op == kNowPeekActOpWindow) {
        spec.postcondition = (cell->window_op == kNowPeekActWinZoom)
                           ? kNowActPostNone : kNowActPostWindow;
        spec.expected_a = cell->win_h;
        spec.expected_b = cell->win_v;
    } else if (cell->op == kNowPeekActOpTextSet) {
        spec.postcondition = kNowActPostText;
        spec.post_object = cell->text_window;
        spec.text_length = (NowPeekU16)cell->text_length;
        if (spec.text_length > kNowPeekActTextMax)
            spec.text_length = kNowPeekActTextMax;
        if (spec.text_length != 0)
            BlockMoveData(cell->text_buf, spec.text, spec.text_length);
    }
    now_act_settlement_begin(&g_settlements, &spec,
                             (NowPeekU32)TickCount());
    g_last_correlation_hi = spec.correlation_hi;
    g_last_correlation_lo = spec.correlation_lo;
    g_last_correlation_valid = 1;
}

NowActStatus now_act_submit(const NowActTarget *target,
                            NowPeekActCell *snapshot)
{
    NowPeekActCell *cell = now_act_cell();
    NowPeekTable   *table = act_table();
    unsigned long   deadline;

    if (cell == NULL || target == NULL || target->a5 == 0) {
        return kNowActNoExtension;
    }
    cell->target_a5 = (NowPeekU32)target->a5;
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
    deadline = (unsigned long)TickCount() + kNowActDeadlineTicks;
    act_v2_describe(table, target, deadline);
    cell->status = kNowPeekActStatusPending;   /* the commit, written last */
    while (cell->status == kNowPeekActStatusPending
           && (unsigned long)TickCount() < deadline) {
        act_yield();
    }
    if (cell->status == kNowPeekActStatusPending) {
        now_act_settlement_note(&g_settlements, g_last_correlation_hi,
                                g_last_correlation_lo,
                                kNowActSettleTimedOut,
                                (NowPeekU32)TickCount());
        now_act_withdraw();
        return kNowActTimeout;
    }
    act_snapshot(cell, snapshot);
    if (snapshot->status != kNowPeekActStatusDone) {
        now_act_settlement_note(&g_settlements, g_last_correlation_hi,
                                g_last_correlation_lo,
                                kNowActSettleRefused,
                                (NowPeekU32)TickCount());
        now_act_withdraw();
        return kNowActRefused;
    }
    now_act_settlement_note_resident(&g_settlements, g_last_correlation_hi,
                                     g_last_correlation_lo,
                                     table->act_v2.resident_stage);
    now_act_settlement_note(&g_settlements, g_last_correlation_hi,
                            g_last_correlation_lo,
                            kNowActSettleDispatchedUnconfirmed,
                            (NowPeekU32)TickCount());
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
        now_act_settlement_note(&g_settlements, g_last_correlation_hi,
                                g_last_correlation_lo,
                                kNowActSettleTimedOut,
                                (NowPeekU32)TickCount());
        now_act_withdraw();
        return kNowActNotTaken;
    }
    now_act_settlement_note_resident(&g_settlements, g_last_correlation_hi,
                                     g_last_correlation_lo,
                                     act_table()->act_v2.resident_stage);
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
    case kNowPeekActErrPostFailed:  return "act-post-failed";
    case kNowPeekActErrNotControlItem: return "not-a-control-item";
    case kNowPeekActErrItemMismatch: return "element-mismatch";
    case kNowPeekActErrItemDisabled: return "item-disabled";
    case kNowPeekActErrIdentity: return "act-identity-mismatch";
    case kNowPeekActErrExpired: return "act-expired";
    case kNowPeekActErrSessionChanged: return "act-session-changed";
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
    case kNowPeekActErrPostFailed:
        return "the Event Manager refused to queue the press, so nothing "
               "was asked of the application at all";
    case kNowPeekActErrNotControlItem:
        return "that dialog item is not a push button, checkbox or radio "
               "button";
    case kNowPeekActErrItemMismatch:
        return "the named dialog item no longer owns the control from the "
               "observation, so the request is stale";
    case kNowPeekActErrItemDisabled:
        return "that dialog item is disabled or no longer visible";
    case kNowPeekActErrIdentity:
        return "the request identity no longer matches its exact operation";
    case kNowPeekActErrExpired:
        return "the request expired before its target could accept it";
    case kNowPeekActErrSessionChanged:
        return "the application writer session changed before the request "
               "could be served";
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
