#include "now_act_guard.h"

#include <stddef.h>

/* No Toolbox here, and no clock - see the header. The resident half
   performs the effects; this file decides, and is the only part of the
   act plane a host test can reach. */

/* The point tolerance for the menu press, in pixels. Loose on purpose:
   an application may hand MenuSelect a point it has adjusted, and a
   guard that is wrong in the STRICT direction breaks the legitimate
   request while leaving the hijack it was written for untouched. */
#define NOW_ACT_POINT_SLOP 2

int now_act_plane_state(const NowPeekTable *table)
{
    unsigned long need;

    if (table == NULL) {
        return kNowActPlaneNoTable;
    }
    if (table->magic != (NowPeekU32)kNowPeekTableMagic
        || table->ext_major != kNowPeekExtMajor) {
        return kNowActPlaneNoTable;
    }
    /* Length FIRST, before act_format is even read: act_format lives
       past the anchor region, so on a resident half that predates the
       plane the read itself is off the end of the block. A gate whose
       first act is the unsafe read is not a gate. */
    need = (unsigned long)offsetof(NowPeekTable, act)
           + (unsigned long)sizeof(NowPeekActCell);
    if ((unsigned long)table->length < need) {
        return kNowActPlaneStale;
    }
    if ((table->caps & (NowPeekU32)kNowPeekTableCapAct) == 0) {
        return kNowActPlaneAbsent;
    }
    if (table->act_format != kNowPeekActFormatV1) {
        return kNowActPlaneWrongFormat;
    }
    return kNowActPlaneReady;
}

/* Does the cell name a patch that exists? A sub-op whose patch was never
   installed is refused here rather than armed: an arm that can never
   fire produces a timeout, and a timeout names the wrong repair. */
static int patches_present(const NowPeekActCell *cell, unsigned long want)
{
    return (cell->patches & (NowPeekU32)want) == (NowPeekU32)want;
}

static int begin_window(NowPeekActCell *cell)
{
    switch (cell->window_op) {
    case kNowPeekActWinMove:
        /* No patch, and nothing to arm: DragWindow returns void, so the
           application asks nothing and there is no answer to give. The
           hook makes the Window Manager call DragWindow would have made,
           which is also what keeps injected mouse motion - and with it
           the emulator - out of this plane entirely. */
        if (cell->window_ptr == 0) {
            cell->error = kNowPeekActErrNoWindow;
            return kNowActServeRefused;
        }
        return kNowActServeMove;

    case kNowPeekActWinResize:
        if (!patches_present(cell, (unsigned long)kNowPeekActPatchFindWindow
                                       | kNowPeekActPatchGrowWindow)) {
            cell->error = kNowPeekActErrNoPatch;
            return kNowActServeRefused;
        }
        break;

    case kNowPeekActWinZoom:
        if (!patches_present(cell, (unsigned long)kNowPeekActPatchFindWindow
                                       | kNowPeekActPatchTrackBox)) {
            cell->error = kNowPeekActErrNoPatch;
            return kNowActServeRefused;
        }
        if (cell->zoom_part != kNowPeekActInZoomIn
            && cell->zoom_part != kNowPeekActInZoomOut) {
            cell->error = kNowPeekActErrBadWindowOp;
            return kNowActServeRefused;
        }
        break;

    case kNowPeekActWinClose:
        if (!patches_present(cell, (unsigned long)kNowPeekActPatchFindWindow
                                       | kNowPeekActPatchTrackGoAway)) {
            cell->error = kNowPeekActErrNoPatch;
            return kNowActServeRefused;
        }
        break;

    default:
        cell->error = kNowPeekActErrBadWindowOp;
        return kNowActServeRefused;
    }

    if (cell->window_ptr == 0) {
        cell->error = kNowPeekActErrNoWindow;
        return kNowActServeRefused;
    }
    cell->fired = 0;
    cell->find_window_fired = 0;
    cell->armed = kNowPeekActArmReady;
    return kNowActServeArmed;
}

int now_act_serve_begin(NowPeekActCell *cell, unsigned long current_a5,
                        unsigned long ticks)
{
    int verdict;

    if (cell == NULL || cell->status != kNowPeekActStatusPending) {
        return kNowActServeSkip;
    }
    /* Not our turn. Some other process's pass will match, and until one
       does the request simply waits - the hook never blocks. */
    if (cell->target_a5 != (NowPeekU32)current_a5) {
        return kNowActServeSkip;
    }

    cell->seq++;                        /* odd: a reader must retry */
    cell->served_a5 = (NowPeekU32)current_a5;
    cell->served_ticks = (NowPeekU32)ticks;
    cell->error = kNowPeekActErrNone;

    switch (cell->op) {
    case kNowPeekActOpMenu:
        if (!patches_present(cell, (unsigned long)kNowPeekActPatchMenu)) {
            cell->error = kNowPeekActErrNoPatch;
            verdict = kNowActServeRefused;
            break;
        }
        /* Arming happens HERE, in the target's own context, rather than
           from the application: it proves the target is alive and
           pumping before any patch goes live, and it means a patch is
           only ever armed while the process it names is running. */
        cell->fired = 0;
        cell->armed = kNowPeekActArmReady;
        verdict = kNowActServeArmed;
        break;

    case kNowPeekActOpControl:
        if (!patches_present(cell, (unsigned long)kNowPeekActPatchControl)) {
            cell->error = kNowPeekActErrNoPatch;
            verdict = kNowActServeRefused;
            break;
        }
        cell->fired = 0;
        cell->armed = kNowPeekActArmReady;
        verdict = kNowActServeArmed;
        break;

    case kNowPeekActOpWindow:
        verdict = begin_window(cell);
        break;

    case kNowPeekActOpTextGet:
    case kNowPeekActOpTextSet:
        cell->text_buf_length = 0;
        cell->text_item_type = 0;
        cell->text_te = 0;
        verdict = kNowActServeText;
        break;

    case kNowPeekActOpSelfTest:
        if (!patches_present(cell, (unsigned long)kNowPeekActPatchMenu)) {
            cell->error = kNowPeekActErrNoPatch;
            verdict = kNowActServeRefused;
            break;
        }
        verdict = kNowActServeSelfTest;
        break;

    default:
        cell->error = kNowPeekActErrBadOp;
        verdict = kNowActServeRefused;
        break;
    }

    if (verdict == kNowActServeRefused) {
        cell->armed = kNowPeekActArmNone;
    }
    return verdict;
}

void now_act_serve_commit(NowPeekActCell *cell, unsigned long error)
{
    if (cell == NULL) {
        return;
    }
    cell->error = (NowPeekU32)error;
    cell->status = (error == kNowPeekActErrNone) ? kNowPeekActStatusDone
                                                 : kNowPeekActStatusError;
    if (error != kNowPeekActErrNone) {
        /* Never leave a patch armed behind a failure. A request left
           armed is a patch waiting to fire on somebody else's call,
           which is the one failure mode a trap patch must not have. */
        cell->armed = kNowPeekActArmNone;
    }
    cell->seq++;                        /* even: the reply is coherent */
}

/* The clause every patch shares, minus its per-op identity check. The
   bypass and the arm state are read first and cheapest: when the plane
   is not armed this is a load and a branch, and every call in the system
   reaches the real trap exactly as it would without us. */
static NowPeekActCell *armed_for(NowPeekActCell *cell, unsigned long op,
                                 unsigned long stage, unsigned long current_a5)
{
    if (cell == NULL || cell->armed != (NowPeekU32)stage) {
        return NULL;
    }
    if (cell->op != (NowPeekU32)op) {
        return NULL;
    }
    if (cell->target_a5 != (NowPeekU32)current_a5) {
        return NULL;            /* somebody else's call; leave it alone */
    }
    return cell;
}

long now_act_menu_answer(NowPeekActCell *cell, unsigned long current_a5,
                         long start_pt, unsigned long ticks)
{
    NowPeekActCell *p = armed_for(cell, (unsigned long)kNowPeekActOpMenu,
                                  (unsigned long)kNowPeekActArmReady,
                                  current_a5);
    long packed;

    if (p == NULL) {
        p = armed_for(cell, (unsigned long)kNowPeekActOpSelfTest,
                      (unsigned long)kNowPeekActArmReady, current_a5);
    }
    if (p == NULL) {
        return 0;
    }

    /* THE GUARD. A menu press carries no handle, so the identity is the
       press: only the event the caller queued has these coordinates,
       because the caller stamps them on the queue element rather than
       leaving `where` to the live mouse. A negative arm point means
       unguarded, which only the selftest uses - it rides no user click
       at all and answers a MenuSelect it made itself. */
    if (p->arm_point_h >= 0) {
        short h = (short)(start_pt & 0xFFFFL);
        short v = (short)((start_pt >> 16) & 0xFFFFL);

        if ((long)h < (long)p->arm_point_h - NOW_ACT_POINT_SLOP
            || (long)h > (long)p->arm_point_h + NOW_ACT_POINT_SLOP
            || (long)v < (long)p->arm_point_v - NOW_ACT_POINT_SLOP
            || (long)v > (long)p->arm_point_v + NOW_ACT_POINT_SLOP) {
            return 0;           /* the user's own press; chain through */
        }
    }

    packed = ((long)(p->menu_id & 0xFFFF) << 16)
             | (long)(p->item_index & 0xFFFF);

    p->armed = kNowPeekActArmNone;      /* one request, one answer */
    p->fired = 1;
    p->served_ticks = (NowPeekU32)ticks;
    p->status = kNowPeekActStatusDone;
    return packed;
}

short now_act_control_answer(NowPeekActCell *cell, unsigned long current_a5,
                             unsigned long control_handle,
                             unsigned long action_proc, unsigned long ticks,
                             unsigned long *out_action)
{
    NowPeekActCell *p = armed_for(cell, (unsigned long)kNowPeekActOpControl,
                                  (unsigned long)kNowPeekActArmReady,
                                  current_a5);

    if (out_action != NULL) {
        *out_action = 0;
    }
    if (p == NULL) {
        return 0;
    }
    /* THE GUARD. This is the clause that measured 0/20 upstream while
       the menu patch without its equivalent measured 18/20: the request
       must name THIS control, or the patch fires on the user's next
       scroll bar drag. */
    if (p->control_handle != (NowPeekU32)control_handle) {
        return 0;
    }

    p->armed = kNowPeekActArmNone;
    p->fired = 1;
    p->served_ticks = (NowPeekU32)ticks;
    p->status = kNowPeekActStatusDone;
    p->saw_action_proc = (NowPeekU32)action_proc;

    if (out_action != NULL
        && action_proc != 0 && action_proc != 0xFFFFFFFFUL
        && p->part_code != 129) {
        /* 0xFFFFFFFF is the Control Manager's "use the control's own"
           sentinel, not an address; the thumb (129) has no action-proc
           semantics. Filtered here so the resident code that does the
           jumping never has to know either fact. */
        *out_action = action_proc;
    }
    return (short)p->part_code;
}

void now_act_trap_hit(NowPeekActCell *cell, int index,
                      unsigned long current_a5)
{
    if (cell == NULL || index < 0 || index > 3) {
        return;
    }
    cell->trap_hits[index]++;
    if (cell->op == (NowPeekU32)kNowPeekActOpWindow
        && cell->armed != kNowPeekActArmNone
        && cell->target_a5 == (NowPeekU32)current_a5) {
        cell->trap_hits_target[index]++;
    }
}

short now_act_findwindow_answer(NowPeekActCell *cell, unsigned long current_a5,
                                unsigned long point, unsigned long ticks,
                                unsigned long *out_window)
{
    NowPeekActCell *p = armed_for(cell, (unsigned long)kNowPeekActOpWindow,
                                  (unsigned long)kNowPeekActArmReady,
                                  current_a5);
    short v;
    short h;
    short part;

    if (p == NULL) {
        /* Answer at stage 2 as well - see the header. This widens the
           guard in no other direction: the point must still be the exact
           one the caller posted, in the target's A5 world. */
        p = armed_for(cell, (unsigned long)kNowPeekActOpWindow,
                      (unsigned long)kNowPeekActArmStage2, current_a5);
    }
    if (p == NULL || out_window == NULL) {
        return 0;
    }
    if (p->window_op == kNowPeekActWinMove) {
        return 0;               /* MOVE never arms a patch */
    }

    /* THE GUARD. A Point is {short v; short h}, so v is the HIGH word. */
    v = (short)((point >> 16) & 0xFFFFUL);
    h = (short)(point & 0xFFFFUL);
    if (!(p->click_h == -1 && p->click_v == -1)
        && ((NowPeekI32)h != p->click_h || (NowPeekI32)v != p->click_v)) {
        return 0;               /* not the click we queued */
    }

    switch (p->window_op) {
    case kNowPeekActWinResize:
        part = kNowPeekActInGrow;
        break;
    case kNowPeekActWinZoom:
        part = (short)p->zoom_part;
        break;
    case kNowPeekActWinClose:
        part = kNowPeekActInGoAway;
        break;
    default:
        return 0;
    }

    *out_window = (unsigned long)p->window_ptr;
    p->find_window_fired = 1;
    p->fw_answers++;
    p->armed = kNowPeekActArmStage2;    /* the second patch may answer */
    p->served_ticks = (NowPeekU32)ticks;
    return part;
}

long now_act_grow_answer(NowPeekActCell *cell, unsigned long current_a5,
                         unsigned long window, unsigned long ticks)
{
    NowPeekActCell *p = armed_for(cell, (unsigned long)kNowPeekActOpWindow,
                                  (unsigned long)kNowPeekActArmStage2,
                                  current_a5);

    if (p == NULL || p->window_op != kNowPeekActWinResize) {
        return 0;
    }
    if (p->window_ptr != (NowPeekU32)window) {
        return 0;               /* a different window; leave it alone */
    }
    p->armed = kNowPeekActArmNone;
    p->fired = 1;
    p->served_ticks = (NowPeekU32)ticks;
    /* HIGH word height, low word width. */
    return (long)((((unsigned long)p->win_v & 0xFFFFUL) << 16)
                  | ((unsigned long)p->win_h & 0xFFFFUL));
}

int now_act_trackbox_answer(NowPeekActCell *cell, unsigned long current_a5,
                            unsigned long window, long part,
                            unsigned long ticks)
{
    NowPeekActCell *p = armed_for(cell, (unsigned long)kNowPeekActOpWindow,
                                  (unsigned long)kNowPeekActArmStage2,
                                  current_a5);

    if (p == NULL || p->window_op != kNowPeekActWinZoom) {
        return 0;
    }
    if (p->window_ptr != (NowPeekU32)window) {
        return 0;
    }
    if (part != (long)p->zoom_part) {
        /* Tracking a different box than the one FindWindow was answered
           with. Declining is the honest move; the request stays at stage
           2 and the caller's timeout withdraws it. */
        return 0;
    }
    p->armed = kNowPeekActArmNone;
    p->fired = 1;
    p->served_ticks = (NowPeekU32)ticks;
    return 1;
}

int now_act_goaway_answer(NowPeekActCell *cell, unsigned long current_a5,
                          unsigned long window, unsigned long ticks)
{
    NowPeekActCell *p = armed_for(cell, (unsigned long)kNowPeekActOpWindow,
                                  (unsigned long)kNowPeekActArmStage2,
                                  current_a5);

    if (p == NULL || p->window_op != kNowPeekActWinClose) {
        return 0;
    }
    if (p->window_ptr != (NowPeekU32)window) {
        return 0;
    }
    p->armed = kNowPeekActArmNone;
    p->fired = 1;
    p->served_ticks = (NowPeekU32)ticks;
    return 1;
}

int now_act_window_is_ours(unsigned long list_head, unsigned long want,
                           NowActNextWindow next, void *ctx)
{
    unsigned long probe = list_head;
    int           guard;

    if (want == 0 || next == NULL) {
        return 0;
    }
    for (guard = 0; probe != 0 && guard < kNowActMaxWindowWalk; guard++) {
        if (probe == want) {
            return 1;
        }
        probe = next(probe, ctx);
    }
    return 0;
}

int now_act_handle_in_zone(unsigned long lo, unsigned long hi,
                           unsigned long addr, unsigned long need)
{
    if (lo == 0 || addr == 0 || hi <= lo || need == 0) {
        return 0;
    }
    if ((hi - lo) < need) {
        return 0;
    }
    /* Room for the master pointer itself, which is the next thing read. */
    if (addr < lo || addr > hi - 4UL) {
        return 0;
    }
    return 1;
}

int now_act_master_in_zone(unsigned long lo, unsigned long hi,
                           unsigned long master, unsigned long need)
{
    if (lo == 0 || hi <= lo || need == 0 || (hi - lo) < need) {
        return 0;
    }
    if (master < lo || master > hi - need) {
        return 0;
    }
    return 1;
}

int now_act_item_type_is_text(long type)
{
    /* itemDisable is 128 and rides in the high bit of the type byte;
       editText is 16 and statText 8 (Dialogs.h). */
    long bare = type & ~128L;

    return bare == 16L || bare == 8L;
}

long now_act_text_take(long requested, long buffer_max)
{
    if (requested < 0) {
        return 0;
    }
    if (buffer_max < 0) {
        return 0;
    }
    return requested > buffer_max ? buffer_max : requested;
}
