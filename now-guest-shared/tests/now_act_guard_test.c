/*
 * now_act_guard_test.c - the act plane's guard, on a host compiler.
 *
 *   cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST -I ../../contract \
 *      -I ../src now_act_guard_test.c ../src/now_act_guard.c -o /tmp/t && /tmp/t
 *
 * WHAT THIS PINS, and why it is the most important test in the port. The
 * act plane executes inside every process that pumps events, on a system
 * with no memory protection, and its guard is the only thing standing
 * between "the request drove the element it named" and "the patch rode
 * the user's own click". Upstream measured that gap at 18/20 versus
 * 0/20. A Macintosh cannot be asked to reproduce it on demand and a
 * clean build proves nothing about it, so it is pinned HERE, where a
 * wrong comparison fails in a second.
 *
 * MUTATIONS WATCHED FAILING (2026-07-31), each reverted after:
 *   - menu: drop the arm-point clause entirely -> the hijack case
 *     answers the user's press. This is the 18/20 defect, reproduced.
 *   - menu: tolerance 2 -> 0 -> the legitimate adjusted press is
 *     refused. The guard erring strict breaks the request, not the
 *     hijack, which is why the slop is loose.
 *   - control: drop the control_handle clause -> the wrong control is
 *     driven.
 *   - findwindow: drop the click-point clause -> a foreign click is
 *     answered.
 *   - grow: swap win_h and win_v in the packing -> 420x260 comes back
 *     260x420.
 *   - plane state: check act_format before length -> a stale table
 *     reports ready, which is the silent-corruption path.
 *   - handle: allow addr == hi -> the master-pointer read runs off the
 *     end of the zone.
 */

#include "now_act_guard.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_failures++;
    }
}

static void check_long(long got, long want, const char *what)
{
    if (got != want) {
        fprintf(stderr, "FAIL: %s (got %ld, want %ld)\n", what, got, want);
        g_failures++;
    }
}

/* A Point as the traps receive it: {short v; short h}, v in the HIGH
   word. Spelled once here so a test that packs it backwards is a test
   that fails, not a test that agrees with a bug. */
static unsigned long point_of(short h, short v)
{
    return (((unsigned long)(unsigned short)v) << 16)
           | (unsigned long)(unsigned short)h;
}

static const unsigned long kTargetA5 = 0x00123456UL;
static const unsigned long kOtherA5 = 0x00999999UL;

static void arm_menu(NowPeekActCell *cell, long h, long v)
{
    memset(cell, 0, sizeof *cell);
    cell->op = kNowPeekActOpMenu;
    cell->target_a5 = (NowPeekU32)kTargetA5;
    cell->armed = kNowPeekActArmReady;
    cell->menu_id = 130;
    cell->item_index = 3;
    cell->arm_point_h = (NowPeekI32)h;
    cell->arm_point_v = (NowPeekI32)v;
    cell->patches = kNowPeekActPatchMenu;
}

/* ---- the menu guard: the 18/20 measurement, as a test ---------------- */

static void test_menu_identity(void)
{
    NowPeekActCell cell;

    /* The request's own press is answered, packed as the Menu Manager
       packs it. */
    arm_menu(&cell, 52, 10);
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10),
                                   42UL),
               ((long)130 << 16) | 3, "menu answers its own press");
    check(cell.armed == kNowPeekActArmNone, "menu disarms after answering");
    check(cell.fired == 1, "menu records that it fired");
    check_long((long)cell.served_ticks, 42L, "menu stamps the answer");

    /* THE DEFECT THIS GUARD EXISTS FOR. A real user presses a different
       menu while the request is armed. Upstream, without this clause,
       that ran the armed command 18 times in 20. */
    arm_menu(&cell, 52, 10);
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(200, 10),
                                   42UL),
               0, "menu declines a press elsewhere in the bar");
    check(cell.armed == kNowPeekActArmReady,
          "a declined press leaves the request armed for its own");
    check(cell.fired == 0, "a declined press did not fire");

    /* Loose by two pixels, in both axes and both directions: an
       application may pass MenuSelect a point it has adjusted. */
    arm_menu(&cell, 52, 10);
    check(now_act_menu_answer(&cell, kTargetA5, (long)point_of(54, 12), 1UL)
              != 0, "menu tolerates +2 px");
    arm_menu(&cell, 52, 10);
    check(now_act_menu_answer(&cell, kTargetA5, (long)point_of(50, 8), 1UL)
              != 0, "menu tolerates -2 px");
    arm_menu(&cell, 52, 10);
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(55, 10),
                                   1UL),
               0, "menu refuses +3 px");

    /* Another process's MenuSelect, at the very same point. The A5 world
       is a separate clause from the point and both are load-bearing. */
    arm_menu(&cell, 52, 10);
    check_long(now_act_menu_answer(&cell, kOtherA5, (long)point_of(52, 10),
                                   1UL),
               0, "menu declines another process's press");

    /* Not armed at all: every call in the system reaches the real trap. */
    arm_menu(&cell, 52, 10);
    cell.armed = kNowPeekActArmNone;
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10),
                                   1UL),
               0, "an unarmed plane answers nothing");

    /* An armed CONTROL request must not be answered by the menu patch. */
    arm_menu(&cell, 52, 10);
    cell.op = kNowPeekActOpControl;
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10),
                                   1UL),
               0, "the menu patch answers only menu ops");

    /* Negative arm point = unguarded, and ONLY the selftest may use it:
       it answers a MenuSelect it made itself and rides no user click. */
    arm_menu(&cell, -1, -1);
    cell.op = kNowPeekActOpSelfTest;
    check(now_act_menu_answer(&cell, kTargetA5, (long)point_of(0, 0), 1UL)
              != 0, "the selftest is deliberately unguarded on the point");
}

/* ---- what the point CANNOT tell apart -------------------------------
 *
 * A CHARACTERISATION test, not an assertion that the code is right. It
 * pins the premise of the probe's `collide` case
 * (scripts/probes/nohijack-probe.py, docs/no-hijack-criterion.md §4) so
 * that a later change either keeps the premise or breaks this test and
 * says so out loud.
 *
 * The menu guard's identity is a POINT, and a point is not unique. There
 * is no serial on the request and nothing on the Event Manager's queue
 * element that says which request queued a press, so two presses at the
 * same coordinates are the same press as far as this code can see. That
 * is not a leak by itself: the resident half queues the request's own
 * press from inside the target's context at the moment of arming
 * (ext/src/now_ext_act.c), so it is normally the first press to arrive
 * AFTER arming and normally the one answered.
 *
 * The case it does not cover is a press already in the queue when the
 * arm happens - which the Event Manager hands over first, and which this
 * guard accepts. The number for that is unmeasured; the probe's
 * `collide` case is written to get it and has never run.
 *
 * If a future guard learns to tell its own press from a stranger's - a
 * cookie in evtQModifiers, a serial in the cell, anything - the two
 * checks below flip and MUST be rewritten rather than deleted. Deleting
 * them would erase the reason they existed. */

static void test_menu_press_is_anonymous(void)
{
    NowPeekActCell cell;

    /* A press at the arm point is answered. The guard is not told, and
       cannot ask, who queued it - so this is the same call whether the
       press came from the resident half or from a hand on the mouse. */
    arm_menu(&cell, 52, 10);
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10),
                                   7UL),
               ((long)130 << 16) | 3,
               "a press at the arm point is answered, whoever queued it");

    /* And the SECOND press at that same point is not, because answering
       disarmed. This is the bound on the exposure above: the window is
       one press wide, not "until the request is withdrawn". Disarming is
       not the guard - it never was - but it is what keeps this case from
       being every press at that point for the next five seconds. */
    check(cell.armed == kNowPeekActArmNone, "answering disarmed");
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10),
                                   8UL),
               0, "the second press at the same point is not answered");
    check_long((long)cell.served_ticks, 7L,
               "and the declined press did not restamp the answer");
}

/* ---- the control guard: the 0/20 half of the same measurement -------- */

static void test_control_identity(void)
{
    NowPeekActCell cell;
    unsigned long  action = 0;

    memset(&cell, 0, sizeof cell);
    cell.op = kNowPeekActOpControl;
    cell.target_a5 = (NowPeekU32)kTargetA5;
    cell.armed = kNowPeekActArmReady;
    cell.control_handle = 0x00A0B0C0UL;
    cell.part_code = 22;                /* inPageDown */
    cell.patches = kNowPeekActPatchControl;

    check_long(now_act_control_answer(&cell, kTargetA5, 0x00A0B0C0UL,
                                      0x00CAFE00UL, 7UL, &action),
               22, "control answers the handle it named");
    check_long((long)action, (long)0x00CAFE00UL,
               "a real action proc is handed back to be called once");
    check(cell.armed == kNowPeekActArmNone, "control disarms after answering");

    /* The clause that measured 0/20: a different control is declined,
       and 0 is TrackControl's own "released outside", so declining is
       indistinguishable from an ordinary miss. */
    cell.armed = kNowPeekActArmReady;
    cell.fired = 0;
    action = 0xDEADUL;
    check_long(now_act_control_answer(&cell, kTargetA5, 0x00FFFFFFUL,
                                      0x00CAFE00UL, 7UL, &action),
               0, "control declines a control it did not name");
    check_long((long)action, 0, "a declined control hands back no action");
    check(cell.armed == kNowPeekActArmReady, "a decline leaves it armed");

    /* -1 is the Control Manager's "use the control's own" sentinel, not
       an address. Calling it would jump to 0xFFFFFFFF. */
    cell.armed = kNowPeekActArmReady;
    action = 0xDEADUL;
    check_long(now_act_control_answer(&cell, kTargetA5, 0x00A0B0C0UL,
                                      0xFFFFFFFFUL, 7UL, &action),
               22, "the sentinel action proc still answers the part code");
    check_long((long)action, 0, "the sentinel is never handed back to call");
    check_long((long)cell.saw_action_proc, (long)0xFFFFFFFFUL,
               "which of the three it was is still reported");

    /* The thumb has no action-proc semantics. */
    cell.armed = kNowPeekActArmReady;
    cell.part_code = 129;
    action = 0xDEADUL;
    check_long(now_act_control_answer(&cell, kTargetA5, 0x00A0B0C0UL,
                                      0x00CAFE00UL, 7UL, &action),
               129, "the thumb answers its part code");
    check_long((long)action, 0, "the thumb calls no action proc");
}

/* ---- the window op: two stages, and a point ------------------------- */

static void arm_window(NowPeekActCell *cell, long op)
{
    memset(cell, 0, sizeof *cell);
    cell->op = kNowPeekActOpWindow;
    cell->target_a5 = (NowPeekU32)kTargetA5;
    cell->armed = kNowPeekActArmReady;
    cell->window_op = (NowPeekI32)op;
    cell->window_ptr = 0x00300400UL;
    cell->click_h = 120;
    cell->click_v = 90;
    cell->patches = (NowPeekU32)(kNowPeekActPatchFindWindow
                                 | kNowPeekActPatchGrowWindow
                                 | kNowPeekActPatchTrackBox
                                 | kNowPeekActPatchTrackGoAway);
}

static void test_window_stages(void)
{
    NowPeekActCell cell;
    unsigned long  window = 0;

    /* Close: FindWindow answers inGoAway, and only then may TrackGoAway
       answer. The stage is the guard - the second patch cannot fire for
       a request whose FindWindow never did. */
    arm_window(&cell, kNowPeekActWinClose);
    check_long(now_act_goaway_answer(&cell, kTargetA5, 0x00300400UL, 1UL),
               0, "TrackGoAway cannot answer before FindWindow has");

    check_long(now_act_findwindow_answer(&cell, kTargetA5,
                                         point_of(120, 90), 5UL, &window),
               kNowPeekActInGoAway, "FindWindow answers inGoAway for close");
    check_long((long)window, (long)0x00300400UL,
               "FindWindow hands back the window the request named");
    check(cell.armed == kNowPeekActArmStage2, "FindWindow advances the stage");
    check_long((long)cell.fw_answers, 1, "the answer is counted");

    /* Upstream measured one posted click producing TWO FindWindow
       entries; a patch that answers only the first lets the real trap
       overrule it with inContent. */
    check_long(now_act_findwindow_answer(&cell, kTargetA5,
                                         point_of(120, 90), 5UL, &window),
               kNowPeekActInGoAway, "FindWindow answers again at stage 2");
    check_long((long)cell.fw_answers, 2, "both answers are counted");

    /* A different window at stage 2 is declined. */
    check_long(now_act_goaway_answer(&cell, kTargetA5, 0x00999999UL, 6UL),
               0, "TrackGoAway declines a window it did not name");
    check_long(now_act_goaway_answer(&cell, kTargetA5, 0x00300400UL, 6UL),
               1, "TrackGoAway answers its own window");
    check(cell.armed == kNowPeekActArmNone, "stage 2 disarms on the way out");

    /* THE GUARD, again: a click somewhere else in the app is not ours. */
    arm_window(&cell, kNowPeekActWinClose);
    check_long(now_act_findwindow_answer(&cell, kTargetA5,
                                         point_of(400, 300), 5UL, &window),
               0, "FindWindow declines a click we did not queue");
    check(cell.armed == kNowPeekActArmReady, "a declined click changes nothing");

    /* And another process's click at the very same point. */
    arm_window(&cell, kNowPeekActWinClose);
    check_long(now_act_findwindow_answer(&cell, kOtherA5,
                                         point_of(120, 90), 5UL, &window),
               0, "FindWindow declines another process's click");

    /* MOVE arms no patch and must never be answered by one. */
    arm_window(&cell, kNowPeekActWinMove);
    check_long(now_act_findwindow_answer(&cell, kTargetA5,
                                         point_of(120, 90), 5UL, &window),
               0, "FindWindow never answers for move");

    /* Zoom: the part FindWindow answered and the part TrackBox is asked
       about must agree, or the application is tracking a different box. */
    arm_window(&cell, kNowPeekActWinZoom);
    cell.zoom_part = kNowPeekActInZoomOut;
    check_long(now_act_findwindow_answer(&cell, kTargetA5,
                                         point_of(120, 90), 5UL, &window),
               kNowPeekActInZoomOut, "FindWindow answers the zoom part");
    check_long(now_act_trackbox_answer(&cell, kTargetA5, 0x00300400UL,
                                       kNowPeekActInZoomIn, 6UL),
               0, "TrackBox declines the other zoom box");
    check_long(now_act_trackbox_answer(&cell, kTargetA5, 0x00300400UL,
                                       kNowPeekActInZoomOut, 6UL),
               1, "TrackBox answers the box FindWindow named");
}

/* ---- the age-out bound: the caller that never came back --------------
 *
 * now_act_submit's own deadline (act_client.c, 300 ticks) only runs if
 * the calling application is still alive to reach it. This is the
 * resident half's OWN backstop for the caller that is not: an armed
 * cell whose served_ticks is older than kNowActArmTicksMax is cleared
 * and declined, with no caller involved at all.
 *
 * MUTATION WATCHED FAILING (revert after use): change the age
 * comparison's `>` to `>=`, or drop it, and this test's "declines"
 * become "answers" - an armed patch answering a click on a Mac where
 * the agent that requested it is long gone. */
static void test_age_out(void)
{
    NowPeekActCell cell;

    /* Just inside the bound: still live, answers normally. */
    arm_menu(&cell, 52, 10);
    cell.served_ticks = 1000UL;
    check(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10),
                              1000UL + kNowActArmTicksMax)
              != 0, "an armed cell right at the edge still answers");

    /* One tick past the bound: the resident half gives up on its own,
       with no caller in the loop at all. */
    arm_menu(&cell, 52, 10);
    cell.served_ticks = 1000UL;
    check_long(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10),
                                   1000UL + kNowActArmTicksMax + 1UL),
               0, "an armed cell past the bound is declined");
    check(cell.armed == kNowPeekActArmNone,
          "aging out clears the arm - not merely declines this call");
    check(cell.status == kNowPeekActStatusIdle,
          "aging out returns the cell to idle, honestly, for the next "
          "caller to see");

    /* A wrapped TickCount (>800 days uptime) must not look like a huge
       elapsed span: unsigned subtraction gives the true forward
       distance, so a cell armed just before the wrap still answers
       just after it. */
    arm_menu(&cell, 52, 10);
    cell.served_ticks = 0xFFFFFFFFUL - 10UL;
    check(now_act_menu_answer(&cell, kTargetA5, (long)point_of(52, 10), 5UL)
              != 0, "the bound survives a TickCount wraparound");

    /* The window plane's stage-2 arm ages out the same way, using the
       served_ticks the FindWindow answer re-stamps at the transition. */
    arm_window(&cell, kNowPeekActWinResize);
    cell.armed = kNowPeekActArmStage2;
    cell.served_ticks = 1000UL;
    check_long(now_act_grow_answer(&cell, kTargetA5, cell.window_ptr,
                                   1000UL + kNowActArmTicksMax + 1UL),
               0, "a stage-2 window request also ages out on its own");
    check(cell.armed == kNowPeekActArmNone,
          "and clears itself rather than waiting on a caller");
}

static void test_grow_packing(void)
{
    NowPeekActCell cell;
    unsigned long  window = 0;
    long           packed;

    arm_window(&cell, kNowPeekActWinResize);
    cell.win_h = 420;                   /* width  */
    cell.win_v = 260;                   /* height */
    check_long(now_act_findwindow_answer(&cell, kTargetA5,
                                         point_of(120, 90), 5UL, &window),
               kNowPeekActInGrow, "FindWindow answers inGrow for resize");

    packed = now_act_grow_answer(&cell, kTargetA5, 0x00300400UL, 6UL);
    /* HIGH word height, low word width. Swapped, a 420x260 request comes
       back 260x420 - which is exactly the mutation to watch fail. */
    check_long((packed >> 16) & 0xFFFF, 260, "GrowWindow's high word is height");
    check_long(packed & 0xFFFF, 420, "GrowWindow's low word is width");
    check(cell.fired == 1, "the resize is recorded as fired");

    /* A different window at stage 2. The sizes have to be NON-ZERO here
       or the check is vacuous: an answer of 0 is also what a request for
       a 0x0 window would pack, so a test that armed no size would pass
       with the window clause removed. (It did, until this line.) */
    arm_window(&cell, kNowPeekActWinResize);
    cell.armed = kNowPeekActArmStage2;
    cell.win_h = 420;
    cell.win_v = 260;
    check_long(now_act_grow_answer(&cell, kTargetA5, 0x00111111UL, 6UL),
               0, "GrowWindow declines a window it did not name");
    check(cell.fired == 0, "and a declined grow did not fire");
}

static void test_trap_hits(void)
{
    NowPeekActCell cell;

    arm_window(&cell, kNowPeekActWinClose);
    /* The global counter is bumped for anyone; the target-scoped one
       only for our own armed request. Without the pair, "the trap was
       never called" and "it was called and declined" are one symptom. */
    now_act_trap_hit(&cell, 0, kOtherA5);
    check_long((long)cell.trap_hits[0], 1, "a foreign entry is still counted");
    check_long((long)cell.trap_hits_target[0], 0,
               "a foreign entry is not counted against the request");
    now_act_trap_hit(&cell, 0, kTargetA5);
    check_long((long)cell.trap_hits_target[0], 1,
               "our own entry is counted against the request");
    now_act_trap_hit(&cell, 9, kTargetA5);   /* out of range: ignored */
    check_long((long)cell.trap_hits[0], 2, "an out-of-range index writes nothing");
}

/* ---- the serve decision --------------------------------------------- */

static void test_serve_begin(void)
{
    NowPeekActCell cell;

    /* Nothing pending: the hook does nothing at all, which is the state
       it is in on every single event-loop pass of a normal machine. */
    memset(&cell, 0, sizeof cell);
    check_long(now_act_serve_begin(&cell, kTargetA5, 1UL), kNowActServeSkip,
               "an idle cell is skipped");

    /* Pending for somebody else: skipped without touching the seqlock,
       so another process's pass can still claim it. */
    arm_menu(&cell, 52, 10);
    cell.armed = kNowPeekActArmNone;
    cell.status = kNowPeekActStatusPending;
    check_long(now_act_serve_begin(&cell, kOtherA5, 1UL), kNowActServeSkip,
               "a request for another A5 world is skipped");
    check_long((long)cell.seq, 0, "a skipped request never opens the seqlock");

    check_long(now_act_serve_begin(&cell, kTargetA5, 99UL), kNowActServeArmed,
               "the named process arms the menu request");
    check(cell.armed == kNowPeekActArmReady, "arming happens in the target");
    check_long((long)cell.seq, 1, "the seqlock is open while writing");
    check_long((long)cell.served_a5, (long)kTargetA5, "the server names itself");
    now_act_serve_commit(&cell, kNowPeekActErrNone);
    check_long((long)cell.seq, 2, "the seqlock closes on commit");
    check_long((long)cell.status, kNowPeekActStatusDone, "commit publishes done");

    /* A sub-op whose patch was never installed is REFUSED, not armed: an
       arm that can never fire produces a timeout, and a timeout names
       the wrong repair. */
    arm_window(&cell, kNowPeekActWinResize);
    cell.armed = kNowPeekActArmNone;
    cell.status = kNowPeekActStatusPending;
    cell.patches = kNowPeekActPatchFindWindow;   /* no GrowWindow */
    check_long(now_act_serve_begin(&cell, kTargetA5, 1UL), kNowActServeRefused,
               "resize without the grow patch is refused");
    check_long((long)cell.error, kNowPeekActErrNoPatch, "and names why");
    check(cell.armed == kNowPeekActArmNone, "a refusal leaves nothing armed");

    /* MOVE is served outright - there is no question for a patch to
       answer, because DragWindow returns void. */
    arm_window(&cell, kNowPeekActWinMove);
    cell.armed = kNowPeekActArmNone;
    cell.status = kNowPeekActStatusPending;
    check_long(now_act_serve_begin(&cell, kTargetA5, 1UL), kNowActServeMove,
               "move is served in-context, not armed");

    /* A window request naming no window is refused before anything runs. */
    arm_window(&cell, kNowPeekActWinMove);
    cell.armed = kNowPeekActArmNone;
    cell.window_ptr = 0;
    cell.status = kNowPeekActStatusPending;
    check_long(now_act_serve_begin(&cell, kTargetA5, 1UL), kNowActServeRefused,
               "a move with no window is refused");
    check_long((long)cell.error, kNowPeekActErrNoWindow, "and names why");

    /* Zoom with a part that is neither zoom box. */
    arm_window(&cell, kNowPeekActWinZoom);
    cell.armed = kNowPeekActArmNone;
    cell.zoom_part = kNowPeekActInContent;
    cell.status = kNowPeekActStatusPending;
    check_long(now_act_serve_begin(&cell, kTargetA5, 1UL), kNowActServeRefused,
               "zoom outside the two zoom parts is refused");
    check_long((long)cell.error, kNowPeekActErrBadWindowOp, "and names why");

    /* An op this build does not know. */
    memset(&cell, 0, sizeof cell);
    cell.op = 99;
    cell.target_a5 = (NowPeekU32)kTargetA5;
    cell.status = kNowPeekActStatusPending;
    check_long(now_act_serve_begin(&cell, kTargetA5, 1UL), kNowActServeRefused,
               "an unknown op is refused");
    check_long((long)cell.error, kNowPeekActErrBadOp, "and names why");

    /* A Dialog Manager item needs no trap. The target-context hook must
       validate the live DITL identity and queue the press itself. */
    memset(&cell, 0, sizeof cell);
    cell.op = kNowPeekActOpDialogItem;
    cell.target_a5 = (NowPeekU32)kTargetA5;
    cell.status = kNowPeekActStatusPending;
    check_long(now_act_serve_begin(&cell, kTargetA5, 1UL),
               kNowActServeDialogItem,
               "a dialog item is handed to the target-context hook");
    check(cell.armed == kNowPeekActArmReady,
          "the dialog press is scoped until the hook validates it");
    check(cell.fired == 0, "a dialog item is not claimed before it is queued");

    /* A failing commit must never leave a patch armed. */
    arm_menu(&cell, 52, 10);
    now_act_serve_commit(&cell, kNowPeekActErrNotOurWindow);
    check(cell.armed == kNowPeekActArmNone,
          "a failed commit disarms; an armed patch waits on someone's click");
    check_long((long)cell.status, kNowPeekActStatusError, "and says error");
}

/* ---- the stale-resident gate ---------------------------------------- */

static void test_plane_state(void)
{
    NowPeekTable table;

    check_long(now_act_plane_state(NULL), kNowActPlaneNoTable,
               "no table is no table");

    memset(&table, 0, sizeof table);
    table.magic = (NowPeekU32)kNowPeekTableMagic;
    table.ext_major = kNowPeekExtMajor;
    table.length = (NowPeekU32)sizeof table;
    table.caps = kNowPeekTableCapAnchors | kNowPeekTableCapAct;
    table.act_format = kNowPeekActFormatV1;
    check_long(now_act_plane_state(&table), kNowActPlaneReady,
               "a current extension is ready");

    /* THE STALE CASE. An extension built before this plane allocated a
       block that ends at the anchors; act_format and the cell are past
       the end of it. Length is checked FIRST for exactly that reason -
       a gate whose first act is the unsafe read is not a gate. */
    table.length = (NowPeekU32)offsetof(NowPeekTable, act_format);
    check_long(now_act_plane_state(&table), kNowActPlaneStale,
               "a resident half that predates the plane is stale");

    /* One byte short of the whole cell is still stale: a partial write
       into a system-heap block is the failure this refuses.

       Stated as the cell's own end rather than as `sizeof table - 1`,
       which is what it said until 2026-07-31 and which quietly stopped
       meaning it the day the content plane appended a field after the
       cell: a length one byte short of the TABLE then covers the cell
       whole, the gate correctly says Ready, and the test that meant to
       watch the gate was watching the last field in the struct. Every
       plane appended here from now on breaks that spelling again, and
       this one does not depend on being last. */
    table.length = (NowPeekU32)(offsetof(NowPeekTable, act)
                                + sizeof(NowPeekActCell) - 1);
    check_long(now_act_plane_state(&table), kNowActPlaneStale,
               "a block one byte short is stale");
    /* And the other side of that line, which is the assertion the old
       spelling was accidentally making: a block that covers the cell but
       stops before a LATER plane's field is Ready for this one. Planes
       are gated separately, by design - that is what accretive means. */
    table.length = (NowPeekU32)(offsetof(NowPeekTable, act)
                                + sizeof(NowPeekActCell));
    check_long(now_act_plane_state(&table), kNowActPlaneReady,
               "a block that covers the act cell and no more is ready");

    table.length = (NowPeekU32)sizeof table;
    table.caps = kNowPeekTableCapAnchors;
    check_long(now_act_plane_state(&table), kNowActPlaneAbsent,
               "a binary that ships the plane dark says absent, not ready");

    table.caps = kNowPeekTableCapAnchors | kNowPeekTableCapAct;
    table.act_format = kNowPeekActFormatV1 + 1;
    check_long(now_act_plane_state(&table), kNowActPlaneWrongFormat,
               "a format this build does not know is refused, not guessed");

    table.act_format = kNowPeekActFormatNone;
    check_long(now_act_plane_state(&table), kNowActPlaneWrongFormat,
               "format zero is not a format");

    table.act_format = kNowPeekActFormatV1;
    table.ext_major = kNowPeekExtMajor + 1;
    check_long(now_act_plane_state(&table), kNowActPlaneNoTable,
               "a different major is never partially trusted");
}

/* ---- the bypass switch ----------------------------------------------- */

static void test_bypass(void)
{
    NowPeekTable table;

    check(now_act_armed_cell(NULL) == NULL, "no table, no cell");

    memset(&table, 0, sizeof table);
    table.magic = (NowPeekU32)kNowPeekTableMagic;
    check(now_act_armed_cell(&table) == NULL,
          "a disarmed plane hands out nothing - every trap chains through");

    table.arm_request = kNowPeekTableCapAnchors;
    check(now_act_armed_cell(&table) == NULL,
          "arming the ANCHOR plane does not arm this one");

    table.arm_request = kNowPeekTableCapAnchors | kNowPeekTableCapAct;
    check(now_act_armed_cell(&table) == &table.act,
          "an armed plane hands out its cell");

    /* arm_request, not arm_active: turning the plane off must not wait
       for the target process to pump. */
    table.arm_active = kNowPeekTableCapAct;
    table.arm_request = 0;
    check(now_act_armed_cell(&table) == NULL,
          "disarming is immediate, and does not consult arm_active");

    table.arm_request = kNowPeekTableCapAct;
    table.magic = 0;
    check(now_act_armed_cell(&table) == NULL,
          "a block that is not a table is never a cell");
}

/* ---- the text ops' identity check ------------------------------------ */

/* A synthetic window list: index i links to i+1, and the seam is what
   makes the bounded walk reachable from here at all. Longer than the
   cap on purpose - the cap is a claim about a corrupt chain, and a list
   that fits inside it cannot test the claim. */
#define kTestLinks 200
static unsigned long g_links[kTestLinks];

static unsigned long next_link(unsigned long window, void *ctx)
{
    (void)ctx;
    if (window < 1 || window > kTestLinks) {
        return 0;
    }
    return g_links[window - 1];
}

static void test_window_is_ours(void)
{
    int i;

    for (i = 0; i < kTestLinks; i++) {
        g_links[i] = (unsigned long)(i + 2);
    }
    g_links[kTestLinks - 1] = 0;

    /* The bound is the whole safety property, so it is asserted rather
       than assumed: a window past the cap is NOT ours, even though it is
       genuinely in the list. Refusing a legitimate write is the correct
       trade against walking a corrupt chain forever. */
    check(now_act_window_is_ours(1, kNowActMaxWindowWalk, next_link, NULL),
          "the last window inside the cap is reachable");
    check(!now_act_window_is_ours(1, kNowActMaxWindowWalk + 1, next_link, NULL),
          "a window past the cap is refused - the bound is real");

    for (i = 0; i < 8; i++) {
        g_links[i] = (unsigned long)(i + 2);
    }
    g_links[7] = 0;

    check(now_act_window_is_ours(1, 1, next_link, NULL),
          "the head is ours");
    check(now_act_window_is_ours(1, 8, next_link, NULL),
          "the tail is ours");
    check(!now_act_window_is_ours(1, 99, next_link, NULL),
          "a window not in the list is refused - this is the write guard");
    check(!now_act_window_is_ours(1, 0, next_link, NULL),
          "a null window is never ours");
    check(!now_act_window_is_ours(0, 1, next_link, NULL),
          "an empty list owns nothing");

    /* A corrupt chain costs a loop count, not the machine. */
    g_links[7] = 1;                       /* close the ring */
    check(!now_act_window_is_ours(1, 99, next_link, NULL),
          "a cycle ends at the cap and proves nothing");
    check(now_act_window_is_ours(1, 5, next_link, NULL),
          "a ring still finds a member within the cap");
}

static void test_handle_bounds(void)
{
    const unsigned long lo = 0x00100000UL;
    const unsigned long hi = 0x00200000UL;

    check(now_act_handle_in_zone(lo, hi, 0x00180000UL, 100UL),
          "an in-zone handle is plausible");
    check(!now_act_handle_in_zone(lo, hi, 1234UL, 100UL),
          "1234 is not a handle - the measured hang this test exists for");
    check(!now_act_handle_in_zone(lo, hi, hi, 100UL),
          "a handle AT the limit has no room for its master pointer");
    check(!now_act_handle_in_zone(lo, hi, 0x00280000UL, 100UL),
          "past the zone is refused");
    check(!now_act_handle_in_zone(0, hi, 0x00180000UL, 100UL),
          "no zone means no plausibility");
    check(!now_act_handle_in_zone(lo, hi, 0x00180000UL, 0UL),
          "a zero-byte need is a caller bug, not a pass");

    check(now_act_master_in_zone(lo, hi, 0x00180000UL, 100UL),
          "an in-zone master pointer is plausible");
    check(!now_act_master_in_zone(lo, hi, hi - 50UL, 100UL),
          "a record that would run past the zone is refused");
    check(!now_act_master_in_zone(lo, hi, lo - 1UL, 100UL),
          "a master pointer below the zone is refused");
}

static void test_item_type(void)
{
    check(now_act_item_type_is_text(16), "editText holds text");
    check(now_act_item_type_is_text(8), "statText holds text");
    /* itemDisable rides in the high bit; an unmasked compare is how a
       disabled static field reads as "not text". */
    check(now_act_item_type_is_text(16 + 128), "a disabled editText still does");
    check(now_act_item_type_is_text(8 + 128), "a disabled statText still does");
    check(!now_act_item_type_is_text(4), "a button holds no text");
    check(!now_act_item_type_is_text(0), "item type zero holds no text");
}

static void test_text_take(void)
{
    check_long(now_act_text_take(10, 256), 10, "a short write is taken whole");
    check_long(now_act_text_take(300, 256), 256,
               "a long write is clamped to what the RESIDENT half allocated");
    check_long(now_act_text_take(-1, 256), 0, "a negative length writes nothing");
    check_long(now_act_text_take(10, 0), 0,
               "an extension with no buffer is written nothing");
}

int main(void)
{
    test_menu_identity();
    test_menu_press_is_anonymous();
    test_control_identity();
    test_window_stages();
    test_age_out();
    test_grow_packing();
    test_trap_hits();
    test_serve_begin();
    test_plane_state();
    test_bypass();
    test_window_is_ours();
    test_handle_bounds();
    test_item_type();
    test_text_take();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("now_act_guard: ok\n");
    return 0;
}
