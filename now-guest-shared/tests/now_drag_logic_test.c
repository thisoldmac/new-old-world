/*
 * now_drag_logic_test.c - watch the dead-man fire.
 *
 * The rule under test is the one whose failure ends with a Macintosh
 * holding the mouse button down inside a tracking loop, unreachable from
 * the host because the host's only channel is the cell the wedged
 * application has stopped reading. It cannot be exercised by driving a
 * guest: to see the dead-man work you must NOT release, and a test that
 * does not release is indistinguishable from a test that failed until
 * something says which.
 *
 * So the decision layer is Toolbox-free (now_drag_logic.c) and this
 * drives it with a tick counter it owns. Every case below was watched
 * failing by mutation before it was kept - the mutations are named
 * beside the cases they belong to.
 *
 *   cc -Wall -Wextra -Werror -I contract -I now-guest-shared/src \
 *      -DNOW_PEEK_TABLE_HOST -o /tmp/t \
 *      now-guest-shared/tests/now_drag_logic_test.c \
 *      now-guest-shared/src/now_drag_logic.c && /tmp/t
 */
#include <stdio.h>
#include <string.h>

#include "now_drag_logic.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

static void check_u32(NowPeekU32 got, NowPeekU32 want, const char *what)
{
    if (got != want) {
        printf("FAIL: %s (got %lu, want %lu)\n", what,
               (unsigned long)got, (unsigned long)want);
        failures++;
    }
}

/* Run the vehicle forward, doing NOTHING - no wants, no heartbeats, no
   release. This is the dead host. Returns the tick at which the session
   ended, or 0 if it never did. */
static NowPeekU32 run_silent(NowPeekDragCell *cell, NowPeekU32 from,
                             NowPeekU32 count)
{
    NowPeekU32 t = from;
    NowPeekU32 i;
    /* Counted, not bounded by `t < from + count`. That form overflows at
       the TickCount wrap and the loop then runs ZERO times - which reads
       as "the dead-man did not fire" and would have made the wrap test
       below pass for entirely the wrong reason. The harness has to
       survive the boundary it is testing. */
    for (i = 0; i < count; i++, t++) {
        if (now_drag_tick(cell, t) == kNowDragTickRelease) {
            return t;
        }
    }
    return 0;
}

static void test_clamps(void)
{
    /* Zero means "did not ask" and gets the default, which is
       deliberately NOT the minimum: a forgotten field must not silently
       select the most aggressive setting available.
       MUTATION: make clamp() return `lo` for 0 and this fails. */
    check_u32(now_drag_clamp_idle(0),
              (NowPeekU32)kNowPeekDragIdleDefaultTicks, "idle default");
    check_u32(now_drag_clamp_cap(0),
              (NowPeekU32)kNowPeekDragCapDefaultTicks, "cap default");

    /* A caller cannot switch the dead-man off, in either direction.
       MUTATION: return `asked` unclamped and both of these fail - which
       is the whole reason the clamp is the RESIDENT's and not the
       caller's. */
    check_u32(now_drag_clamp_idle(1),
              (NowPeekU32)kNowPeekDragIdleMinTicks, "idle floor");
    check_u32(now_drag_clamp_idle(0xFFFFFFFFUL),
              (NowPeekU32)kNowPeekDragIdleMaxTicks, "idle ceiling");
    check_u32(now_drag_clamp_cap(1),
              (NowPeekU32)kNowPeekDragCapMinTicks, "cap floor");
    check_u32(now_drag_clamp_cap(0xFFFFFFFFUL),
              (NowPeekU32)kNowPeekDragCapMaxTicks, "cap ceiling");

    /* A value inside the range is honoured, or the clamp would be a
       constant wearing a function's clothes. */
    check_u32(now_drag_clamp_idle(120), 120, "idle honoured");
}

static void test_press_holds(void)
{
    NowPeekDragCell cell;
    memset(&cell, 0, sizeof cell);

    check(now_drag_begin(&cell, 7, 0xA5A5, 100, 200, 1000, 0, 0) == 1,
          "press accepted");
    check_u32(cell.state, (NowPeekU32)kNowPeekDragStateHeld, "held");
    check_u32(cell.button_down, 1, "button down");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndNone, "no end");
    check(cell.origin_h == 100 && cell.origin_v == 200, "origin recorded");
    check(cell.at_h == 100 && cell.at_v == 200, "at starts at origin");

    /* Single-flight: one mouse button, so a second press is refused
       rather than queued - the only thing a queue could achieve here is
       holding the button down longer.
       MUTATION: drop the state check in now_drag_begin and this fails. */
    check(now_drag_begin(&cell, 8, 0xA5A5, 1, 1, 1001, 0, 0) == 0,
          "second press refused");
    check_u32(cell.session, 7, "first session survives the refusal");

    /* A session numbered 0 could be ended by a caller that named
       nothing, because 0 is release_request's "no session" value. */
    memset(&cell, 0, sizeof cell);
    check(now_drag_begin(&cell, 0, 0xA5A5, 1, 1, 1, 0, 0) == 0,
          "session 0 refused");
}

static void test_dead_man_idle(void)
{
    NowPeekDragCell cell;
    NowPeekU32 ended;
    memset(&cell, 0, sizeof cell);

    now_drag_begin(&cell, 7, 0xA5A5, 10, 10, 1000, 60, 600);
    /* THE CASE THIS FILE EXISTS FOR. Nobody releases. Nobody
       heartbeats. The host is gone.
       MUTATION: delete the idle branch in now_drag_tick and this hangs
       at "never released" instead of passing - which is exactly the
       symptom on a real machine, and why it is worth watching. */
    ended = run_silent(&cell, 1001, 400);
    check(ended != 0, "the dead-man fired without being told");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndDeadManIdle,
              "idle expiry");
    check_u32(cell.button_down, 0, "button released");
    check_u32(cell.state, (NowPeekU32)kNowPeekDragStateEnded, "ended");
    check_u32(cell.pending_mouseup, 1, "the event is owed");
    check_u32(ended, 1060, "fired at begin + idle");

    /* And it stays ended. A vehicle that re-fired would keep writing the
       button every tick forever. */
    check(now_drag_tick(&cell, 2000) == kNowDragTickNothing,
          "an ended session ticks to nothing");
}

static void test_heartbeat_holds_it_open_but_the_cap_does_not(void)
{
    NowPeekDragCell cell;
    NowPeekU32 t;
    int released = 0;
    memset(&cell, 0, sizeof cell);

    now_drag_begin(&cell, 7, 0xA5A5, 10, 10, 1000, 60, 300);
    /* A host that heartbeats faithfully forever. The idle clock never
       expires - and the CAP still ends the gesture, which is the whole
       reason there are two clocks. One timer that the measured thing can
       refresh measures nothing; this project has already paid for that
       once, when a polling probe kept alive the very silence it existed
       to detect.
       MUTATION: delete the cap branch and this fails at "the cap fired
       anyway" while every other test still passes. */
    for (t = 1001; t < 1001 + 600; t++) {
        cell.heartbeat_ticks = t;       /* the host, relayed, alive */
        if (now_drag_tick(&cell, t) == kNowDragTickRelease) {
            released = 1;
            break;
        }
    }
    check(released, "the cap fired anyway");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndDeadManCap,
              "cap expiry");
    check_u32(cell.button_down, 0, "button released");
    check_u32(t, 1300, "fired at begin + cap");
}

static void test_motion(void)
{
    NowPeekDragCell cell;
    memset(&cell, 0, sizeof cell);
    now_drag_begin(&cell, 7, 0xA5A5, 10, 10, 1000, 60, 600);

    /* A want is consumed only when its COMMIT word changes. Two 32-bit
       stores are not one write, and a tick can land between them.
       MUTATION: act on want_h/want_v every tick regardless and this
       fails at "no want, no move". */
    cell.want_h = 50; cell.want_v = 60;
    check(now_drag_tick(&cell, 1001) == kNowDragTickNothing,
          "no want, no move");
    check(cell.at_h == 10, "and the pointer did not move");

    cell.want_seq = 1;
    check(now_drag_tick(&cell, 1002) == kNowDragTickMove, "want consumed");
    check(cell.at_h == 50 && cell.at_v == 60, "pointer followed");
    check_u32(cell.moves_applied, 1, "the last want consumed");
    check(now_drag_tick(&cell, 1003) == kNowDragTickNothing,
          "the same want is not consumed twice");

    /* A want is also a sign of life and holds the idle clock open: the
       deadline is now measured from 1002, when the want was consumed,
       not from the press at 1000. */
    check(run_silent(&cell, 1004, 58) == 0, "still held one tick early");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndNone, "still held");
    check_u32(run_silent(&cell, 1062, 4), 1062, "and fires at want + idle");
}

static void test_release(void)
{
    NowPeekDragCell cell;
    memset(&cell, 0, sizeof cell);
    now_drag_begin(&cell, 7, 0xA5A5, 10, 10, 1000, 60, 600);

    /* A release that names a stale session is dropped, and the session
       RUNS ON. Without this, a release belonging to a gesture that
       already timed out would end the next one - and from the cell alone
       those two writes are identical.
       MUTATION: make release_request a boolean and this fails. */
    check(now_drag_request_release(&cell, 999) == 0, "stale nonce refused");
    check(now_drag_tick(&cell, 1001) == kNowDragTickNothing,
          "and the drag is still held");
    check_u32(cell.state, (NowPeekU32)kNowPeekDragStateHeld, "still held");

    check(now_drag_request_release(&cell, 7) == 1, "own nonce accepted");
    check(now_drag_tick(&cell, 1002) == kNowDragTickRelease, "released");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndReleased,
              "released for the stated reason");
    check_u32(cell.button_down, 0, "button up");
    check_u32(cell.pending_mouseup, 1, "the event is owed");

    /* A release for an ended session does nothing rather than reopening
       one. */
    check(now_drag_request_release(&cell, 7) == 0, "release after the end");
}

static void test_dead_man_beats_a_release_in_the_same_tick(void)
{
    NowPeekDragCell cell;
    memset(&cell, 0, sizeof cell);
    now_drag_begin(&cell, 7, 0xA5A5, 10, 10, 1000, 60, 600);
    now_drag_request_release(&cell, 7);

    /* Both are true on this tick. The dead-man wins, and the END REASON
       is what carries the difference to the host: a gesture that expired
       and one that was released are not the same gesture, and reporting
       the friendlier of the two would be exactly the "plausible wrong
       answer" this arc exists to stop.
       MUTATION: move the release check above the deadline checks and
       this fails while nothing else does. */
    check(now_drag_tick(&cell, 1060) == kNowDragTickRelease, "ended");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndDeadManIdle,
              "and it says the deadline did it, not the host");
}

static void test_abandon(void)
{
    NowPeekDragCell cell;
    memset(&cell, 0, sizeof cell);
    now_drag_begin(&cell, 7, 0xA5A5, 10, 10, 1000, 60, 600);

    /* The plane was disarmed under a live gesture. The button still goes
       up - never optional - but the gesture is recorded as lost, so
       nothing downstream can read a withdrawn drag as a completed one. */
    check(now_drag_abandon(&cell, 1010) == kNowDragTickRelease, "abandoned");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndSessionLost,
              "session lost");
    check_u32(cell.button_down, 0, "button up");

    /* Abandoning an idle cell is a no-op, not a spurious release. */
    check(now_drag_abandon(&cell, 1011) == kNowDragTickNothing,
          "abandon is idempotent");
    check(now_drag_abandon(NULL, 1) == kNowDragTickNothing, "NULL is safe");
    check(now_drag_tick(NULL, 1) == kNowDragTickNothing, "NULL ticks safe");
}

static void test_tick_wraparound(void)
{
    NowPeekDragCell cell;
    NowPeekU32 ended;
    memset(&cell, 0, sizeof cell);

    /* TickCount wraps. A deadline computed as `now >= then + limit` is
       wrong across the boundary and the failure is a drag that never
       times out - i.e. exactly the wedged machine, once every 2.3 years
       of uptime, which is the kind of bug nobody ever reproduces.
       MUTATION: rewrite elapsed_at_least as `now >= then + limit` and
       this fails while every other case passes. */
    now_drag_begin(&cell, 7, 0xA5A5, 10, 10, 0xFFFFFFE0UL, 60, 600);
    ended = run_silent(&cell, 0xFFFFFFE1UL, 400);
    check(ended != 0, "the dead-man fires across a TickCount wrap");
    check_u32(cell.end_reason, (NowPeekU32)kNowPeekDragEndDeadManIdle,
              "and for the right reason");
}

int main(void)
{
    test_clamps();
    test_press_holds();
    test_dead_man_idle();
    test_heartbeat_holds_it_open_but_the_cap_does_not();
    test_motion();
    test_release();
    test_dead_man_beats_a_release_in_the_same_tick();
    test_abandon();
    test_tick_wraparound();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
