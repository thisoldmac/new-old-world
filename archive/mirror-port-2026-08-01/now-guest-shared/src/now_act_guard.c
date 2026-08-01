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
    /* EXACT match, same discipline V1 used: each format adds fields the
       one before has no room for - V2's key/menugeom, V3's click split,
       V4's pump handshake - so a mismatched pair is refused rather than
       partially trusted. The halves ship together (docs/resident-
       components.md), so a mismatch here is a build/deploy mistake, not
       a compatibility case worth degrading through. V4 makes that gate
       sharper still: a V3 resident would leave the plane armed on a
       click route that has no process to serve it. */
    if (table->act_format != kNowPeekActFormatV4) {
        return kNowActPlaneWrongFormat;
    }
    return kNowActPlaneReady;
}

NowPeekActCell *now_act_armed_cell(NowPeekTable *table)
{
    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic) {
        return NULL;
    }
    if ((table->arm_request & (NowPeekU32)kNowPeekTableCapAct) == 0) {
        return NULL;                    /* bypassed: behave as if absent */
    }
    return &table->act;
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

    /* V2: served outright, like the text ops above - no patch to check,
       because neither answers a trap the application calls. */
    case kNowPeekActOpKey:
        verdict = kNowActServeKey;
        break;

    case kNowPeekActOpMenuGeom:
        cell->menu_item_count = 0;
        cell->menu_width = 0;
        cell->menu_height = 0;
        verdict = kNowActServeMenuGeom;
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

int now_act_click_due(const NowPeekActCell *cell, unsigned long current_a5)
{
    if (cell == NULL || cell->click_pending == 0) {
        return 0;
    }
    /* current_a5 of zero is nobody's world and never posts. click_not_a5
       of zero excludes nobody - the application's way of saying "the
       next pass, whoever it belongs to", which on this machine is the
       target's own and is still a LATER pass than the one that armed. */
    if (current_a5 == 0) {
        return 0;
    }
    return cell->click_not_a5 != (NowPeekU32)current_a5;
}

void now_act_click_done(NowPeekActCell *cell, int posted)
{
    if (cell == NULL) {
        return;
    }
    cell->click_posted = posted ? 1UL : 0UL;
    /* Last, and after click_posted: the flag clearing is the publish, and
       an application that reads the answer before it was written would
       report a refusal that never happened. */
    cell->click_pending = 0;
}

/* The clause every patch shares, minus its per-op identity check. The
   bypass and the arm state are read first and cheapest: when the plane
   is not armed this is a load and a branch, and every call in the system
   reaches the real trap exactly as it would without us.
 *
 * `ticks` is the CURRENT trap call's tick, from the same LMGetTicks() the
 * caller already reads to answer with. Compared against served_ticks -
 * the tick this stage was armed at - it is the resident half's own
 * age-out: subtraction done in exactly 32 bits (NowPeekU32, what
 * TickCount and this table's fields actually are) so a wraparound
 * mid-session still yields the true forward distance regardless of how
 * wide `unsigned long` is on the compiler doing the subtracting - 32
 * bits on the 68K/PPC guest this runs on, 64 on the host cc that builds
 * this file's own test. A cell that ages out is cleared HERE, not merely
 * declined, so a second late call does not pay the same stale check
 * again and does not find a patch still nominally "ready" for a request
 * that has already been given up on. */
static NowPeekActCell *armed_for(NowPeekActCell *cell, unsigned long op,
                                 unsigned long stage, unsigned long current_a5,
                                 unsigned long ticks)
{
    NowPeekU32 age;

    if (cell == NULL || cell->armed != (NowPeekU32)stage) {
        return NULL;
    }
    if (cell->op != (NowPeekU32)op) {
        return NULL;
    }
    age = (NowPeekU32)ticks - cell->served_ticks;
    if (age > (NowPeekU32)kNowActArmTicksMax) {
        /* Nobody is coming back for this one. Clear it so the patch
           stops matching and the next caller sees an idle, honest cell
           rather than one "armed" for a request that timed out with no
           one left to say so. */
        cell->armed = kNowPeekActArmNone;
        cell->status = kNowPeekActStatusIdle;
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
                                  current_a5, ticks);
    long packed;

    if (p == NULL) {
        p = armed_for(cell, (unsigned long)kNowPeekActOpSelfTest,
                      (unsigned long)kNowPeekActArmReady, current_a5, ticks);
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
                                  current_a5, ticks);

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
                                  current_a5, ticks);
    short v;
    short h;
    short part;

    if (p == NULL) {
        /* Answer at stage 2 as well - see the header. This widens the
           guard in no other direction: the point must still be the exact
           one the caller posted, in the target's A5 world. */
        p = armed_for(cell, (unsigned long)kNowPeekActOpWindow,
                      (unsigned long)kNowPeekActArmStage2, current_a5, ticks);
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
                                  current_a5, ticks);

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
                                  current_a5, ticks);

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
                                  current_a5, ticks);

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

/* ---- the verb patches' entry counters (V4) ----------------------------- */

/* The appended region's own gate, and it is length + format rather than
   a nonzero field for the reason stated in this file's stale-resident
   note: a zeroed word past the end of a shorter block reads exactly like
   an idle one. Shared by every P4b entry point below. */
static NowPeekTable *pump_table(NowPeekTable *table)
{
    unsigned long need;

    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic
        || table->ext_major != kNowPeekExtMajor) {
        return NULL;
    }
    need = (unsigned long)offsetof(NowPeekTable, act_control_hits_target)
           + 4UL;
    if ((unsigned long)table->length < need) {
        return NULL;
    }
    if (table->act_format != kNowPeekActFormatV4) {
        return NULL;
    }
    return table;
}

void now_act_verb_trap_hit(NowPeekTable *table, int which,
                           unsigned long current_a5)
{
    NowPeekTable *t = pump_table(table);
    unsigned long want_op;
    int           armed;

    if (t == NULL
        || (which != kNowActVerbMenu && which != kNowActVerbControl)) {
        return;
    }
    want_op = which == kNowActVerbMenu ? (unsigned long)kNowPeekActOpMenu
                                       : (unsigned long)kNowPeekActOpControl;
    /* Target-scoped only when a request of THIS op is armed for the A5
       running right now. The global counter cannot tell our own call from
       any other process's, which is ambiguous exactly where it matters. */
    armed = t->act.armed != (NowPeekU32)kNowPeekActArmNone
            && t->act.op == (NowPeekU32)want_op
            && t->act.target_a5 == (NowPeekU32)current_a5;
    if (which == kNowActVerbMenu) {
        t->act_menu_hits++;
        if (armed) {
            t->act_menu_hits_target++;
        }
    } else {
        t->act_control_hits++;
        if (armed) {
            t->act_control_hits_target++;
        }
    }
}

/* ---- the pump handshake (P4b) ------------------------------------------ */

NowPeekActPump *now_act_pump(NowPeekTable *table)
{
    NowPeekTable *t = pump_table(table);

    if (t == NULL) {
        return NULL;
    }
    if ((t->caps & (NowPeekU32)kNowPeekTableCapAct) == 0) {
        return NULL;
    }
    return &t->act_pump;
}

int now_act_stamp_fresh(unsigned long stamp, unsigned long ticks,
                        unsigned long window)
{
    unsigned long age;

    if (stamp == 0) {
        return 0;                       /* absent, not stale */
    }
    age = (unsigned long)(NowPeekU32)((NowPeekU32)ticks - (NowPeekU32)stamp);
    return age <= window;
}

int now_act_pump_alive(const NowPeekActPump *pump, unsigned long ticks)
{
    if (pump == NULL
        || pump->pump_state != (NowPeekU32)kNowPeekActPumpRunning) {
        return 0;
    }
    return now_act_stamp_fresh((unsigned long)pump->pump_heartbeat, ticks,
                               (unsigned long)kNowPeekActPumpTicks);
}

int now_act_session_alive(const NowPeekActPump *pump, unsigned long ticks)
{
    if (pump == NULL) {
        return 0;
    }
    return now_act_stamp_fresh((unsigned long)pump->session_heartbeat, ticks,
                               (unsigned long)kNowPeekActSessionTicks);
}

int now_act_click_route(const NowPeekActPump *pump, unsigned long ticks)
{
    return now_act_pump_alive(pump, ticks) ? kNowActClickPump
                                           : kNowActClickInline;
}

unsigned long now_act_click_request(NowPeekActPump *pump, long h, long v,
                                    long mods, long count)
{
    NowPeekU32 ticket;

    if (pump == NULL) {
        return 0;
    }
    if (count < 1) {
        count = 1;
    }
    if (count > 3) {
        count = 3;                      /* single / double / triple */
    }
    pump->click_h = (NowPeekI32)h;
    pump->click_v = (NowPeekI32)v;
    pump->click_mods = (NowPeekI32)mods;
    pump->click_count = (NowPeekI32)count;
    pump->click_error = kNowPeekActErrNone;
    ticket = (NowPeekU32)(pump->click_pending + 1);
    if (ticket == pump->click_posted) {
        /* Four billion requests later the counter has lapped the reply,
           and the two would agree with nothing served. Skipping one
           value costs nothing and keeps "pending != posted" the only
           thing either side has to read. */
        ticket++;
    }
    pump->click_pending = ticket;       /* the commit, written last */
    return (unsigned long)ticket;
}

int now_act_click_state(const NowPeekActPump *pump, unsigned long ticket)
{
    if (pump == NULL || pump->click_posted != (NowPeekU32)ticket) {
        return kNowActTicketWaiting;
    }
    return pump->click_error == kNowPeekActErrNone ? kNowActTicketPosted
                                                   : kNowActTicketRefused;
}

int now_act_pump_click_due(const NowPeekActPump *pump, NowActClickOrder *out)
{
    NowPeekU32 want;

    if (pump == NULL || out == NULL) {
        return 0;
    }
    want = pump->click_pending;
    if (want == pump->click_posted) {
        return 0;
    }
    out->ticket = (unsigned long)want;
    out->h = (long)pump->click_h;
    out->v = (long)pump->click_v;
    out->mods = (long)pump->click_mods;
    out->count = (long)pump->click_count;
    if (out->count < 1) {
        out->count = 1;
    }
    if (out->count > 3) {
        out->count = 3;
    }
    /* Re-read the commit word. If the filter published a second request
       while we were copying, the copy pairs one request's point with
       another's ticket - so drop it and take the whole thing next pass.
       Nothing is lost: the newer request is still pending. */
    if (pump->click_pending != want) {
        return 0;
    }
    return 1;
}

void now_act_pump_click_done(NowPeekActPump *pump, unsigned long ticket,
                             unsigned long error)
{
    if (pump == NULL) {
        return;
    }
    pump->click_error = (NowPeekU32)error;
    pump->click_posted = (NowPeekU32)ticket;   /* the commit, written last */
}

void now_act_session_beat(NowPeekActPump *pump, unsigned long ticks)
{
    if (pump == NULL) {
        return;
    }
    /* 0 is the "no session" value, so a beat that lands exactly on tick
       zero must not read as the session closing. One tick's error, once
       per wrap of an uptime counter, against a state that would
       otherwise be a lie. */
    pump->session_heartbeat = (NowPeekU32)ticks == 0 ? 1 : (NowPeekU32)ticks;
}

void now_act_session_end(NowPeekActPump *pump)
{
    if (pump == NULL) {
        return;
    }
    pump->session_heartbeat = 0;
}

void now_act_pump_attach(NowPeekActPump *pump, unsigned long ticks)
{
    if (pump == NULL) {
        return;
    }
    pump->click_error = kNowPeekActErrNone;
    pump->click_posted = pump->click_pending;   /* adopt, never replay */
    pump->pump_heartbeat = (NowPeekU32)ticks == 0 ? 1 : (NowPeekU32)ticks;
    pump->pump_state = kNowPeekActPumpRunning;  /* the commit */
}

void now_act_pump_beat(NowPeekActPump *pump, unsigned long ticks)
{
    if (pump == NULL) {
        return;
    }
    pump->pump_heartbeat = (NowPeekU32)ticks == 0 ? 1 : (NowPeekU32)ticks;
}

void now_act_pump_detach(NowPeekActPump *pump)
{
    if (pump == NULL) {
        return;
    }
    pump->pump_state = kNowPeekActPumpExiting;
    pump->pump_heartbeat = 0;
}

int now_act_pump_should_exit(const NowPeekActPump *pump, unsigned long ticks,
                             unsigned long started, int seen_session)
{
    if (pump == NULL) {
        return 1;                       /* nothing to serve, no way to be
                                           asked - see the header */
    }
    if (now_act_session_alive(pump, ticks)) {
        return 0;
    }
    if (seen_session) {
        return 1;                       /* it was there and it stopped */
    }
    /* Never seen one. Wait out the grace window, then go: the pump is
       launched BY the application, so it can easily be running before
       the first beat - but a pump nobody ever beat at is an orphan from
       an earlier session, and exiting is the whole point of this clock. */
    return (unsigned long)(NowPeekU32)((NowPeekU32)ticks - (NowPeekU32)started)
           > (unsigned long)kNowPeekActPumpGraceTicks;
}
