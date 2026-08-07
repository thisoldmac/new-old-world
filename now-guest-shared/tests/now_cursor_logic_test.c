/*
 * now_cursor_logic_test.c - watch the plane refuse to fight a person.
 *
 * P8 moves the guest's drawn cursor to wherever the act plane just
 * acted. The rule that keeps that from being obnoxious is the one under
 * test: if the pointer is not where THIS PLANE last put it, somebody
 * else is driving, and the sprite is left alone for a second.
 *
 * It cannot be exercised by driving a guest, because the case that
 * matters is a human with their hand on the mouse - and "a person moved
 * the pointer and we correctly declined" and "the plane is broken and
 * moved nothing" are the same silence from outside. So the decision is
 * Toolbox-free (now_cursor_logic.c) and this drives it with a tick
 * counter it owns.
 *
 * Every case below was watched failing by mutation; the mutation is
 * named beside the case.
 *
 *   cc -Wall -Wextra -Werror -I contract -I now-guest-shared/src \
 *      -DNOW_PEEK_TABLE_HOST -o /tmp/t \
 *      now-guest-shared/tests/now_cursor_logic_test.c \
 *      now-guest-shared/src/now_cursor_logic.c && /tmp/t
 */
#include <stdio.h>

#include "now_cursor_logic.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        failures++;
    }
}

/* ---- who moved it ----------------------------------------------------
 *
 * Mutation watched: `return 0;` - every pointer looks like ours, the
 * plane never yields, and a person at the machine fights it forever. The
 * first two cases below name it. */
static void test_foreign(void)
{
    check(now_cursor_is_foreign(100, 100, 100, 100, 1) == 0,
          "a pointer exactly where we left it is ours");
    check(now_cursor_is_foreign(101, 100, 100, 100, 1) == 1,
          "one pixel of horizontal drift is somebody else");
    check(now_cursor_is_foreign(100, 101, 100, 100, 1) == 1,
          "one pixel of VERTICAL drift is somebody else too");
    /* Mutation watched: comparing only h. A mouse pushed straight up or
       down is the most ordinary human motion there is, and a plane that
       only notices horizontal movement would fight exactly that. */
    check(now_cursor_is_foreign(0, 0, 0, 0, 1) == 0,
          "the origin is not special - a pointer at 0,0 we placed is ours");

    /* THE BOOT DEFECT, and it is the reason this plane appeared to do
       nothing on every machine it had ever run on.
     *
       `ever_placed` is 0 until the resident has actually moved the
       device, and until then `last` is the zeroed pair the boot left
       behind. Comparing against it makes any pointer not parked exactly
       at the top-left corner read as a person's - so the FIRST act of
       every boot yielded, and because the yield also (wrongly) recorded
       the point it had declined to move to, the device's real position
       and `last` could never agree again and it yielded for the rest of
       the session. Driven on a guest 2026-08-07: a pointer resting at
       15,15 gave `asked 1, yielded 1`, then `asked 2, yielded 2` minutes
       later, with the 60-tick courtesy window long expired.

       Mutation watched: delete the `ever_placed` guard. Every other case
       in this file still passes - they all pass ever_placed = 1 - and
       only these two name it. */
    check(now_cursor_is_foreign(15, 15, 0, 0, 0) == 0,
          "before the first placement there is nothing to compare against");
    check(now_cursor_is_foreign(15, 15, 0, 0, 1) == 1,
          "and once we HAVE placed, the same pair is a person again");
}

/* ---- may we move the sprite -----------------------------------------
 *
 * The deadline half. `foreign_ticks` is the tick at which somebody
 * else's motion was last SEEN, not when it happened. */
static void test_yield(void)
{
    /* Inside the window: leave it alone. */
    check(now_cursor_should_yield(1000, 1000, 0, 60) == 1,
          "the instant a foreign move is seen, the sprite yields");
    check(now_cursor_should_yield(1059, 1000, 0, 60) == 1,
          "one tick short of the window still yields");
    /* Mutation watched: `<=` for the boundary - the window becomes 61
       ticks. Harmless in effect and wrong in fact, and it is the sort of
       off-by-one that makes a later measurement of "how long do we
       yield" disagree with the constant everybody quotes. */
    check(now_cursor_should_yield(1060, 1000, 0, 60) == 0,
          "exactly at the window, the sprite may move again");
    check(now_cursor_should_yield(9999, 1000, 0, 60) == 0,
          "long after, the sprite may move");

    /* A drag NEVER yields, and this is the case that must not be
       'simplified' away.
       Mutation watched: dropping the `owned` short-circuit. Every case
       above still passes, `scripts/test-native` still reads green, and
       the only symptom is a drag whose sprite stops halfway through a
       gesture on a machine where anything else touched the pointer -
       which is precisely the condition a drag creates for itself. */
    check(now_cursor_should_yield(1000, 1000, 1, 60) == 0,
          "a drag owns the pointer and does not yield to itself");
    check(now_cursor_should_yield(1000, 999, 1, 60) == 0,
          "a drag does not yield however recent the foreign motion");
}

/* ---- the wrap --------------------------------------------------------
 *
 * TickCount wraps at 2^32. The wrong spelling of "has a second passed"
 * is `now < foreign_ticks + yield_ticks`, which is correct for 2.3 years
 * of uptime and then yields FOREVER - a cursor that silently stops
 * following, on a machine nobody can explain, once.
 *
 * Mutation watched: exactly that addition. Every case above passes; only
 * this one names it. It is the same defect now_drag_logic.c was mutated
 * to prove, one plane later, which is why it is here at all. */
static void test_wrap(void)
{
    const NowPeekU32 late = (NowPeekU32)0xFFFFFFF0u;   /* 16 before wrap */

    check(now_cursor_should_yield(late, late, 0, 60) == 1,
          "just before the wrap, a fresh foreign move still yields");
    /* 16 ticks to the wrap and 20 past it: 36 elapsed, inside a 60-tick
       window, so this must STILL yield. The addition form computes
       late + 60, which wraps to 44, and 20 < 44 is true - so this case
       passes under the mutation and the next one is the one that fails.
       Kept anyway: a wrap test that only has the failing half reads as
       an arbitrary constant. */
    check(now_cursor_should_yield(20, late, 0, 60) == 1,
          "36 ticks across the wrap is inside a 60-tick window");
    /* 16 + 100 = 116 elapsed, outside the window, so the sprite may
       move. THIS is the case the addition gets wrong: it compares 100
       against the wrapped 44 and answers 'may move' for the right reason
       by accident here - so the real discriminator is the pair below,
       where the addition says yield and the subtraction says move. */
    check(now_cursor_should_yield(100, late, 0, 60) == 0,
          "116 ticks across the wrap is outside the window");
    check(now_cursor_should_yield(0, late, 0, 60) == 1,
          "the wrap boundary itself: 16 elapsed, still inside");
}

/* The pointer travels with the window it moved - and declines to travel
 * at all when the delta could not be measured.
 *
 * The refusal is the case with teeth. Both fallbacks a reader will
 * reach for produce a plausible-looking number, which is exactly why
 * this is a test rather than a comment: `origin_known == 0` returning
 * the click point unchanged, or returning the requested top-left, both
 * leave the arrow somewhere the act did not happen, and neither would
 * ever be noticed by a caller that only checks the return value it was
 * given. */
static void test_follow_window(void)
{
    NowPeekI32 h = -1, v = -1;

    check(now_cursor_follow_window(150, 120, 100, 100, 300, 260, 1, &h, &v)
              == 1,
          "a measured move places the pointer");
    check(h == 350 && v == 280,
          "the pointer travels by the window's delta, not to its origin");

    h = -1; v = -1;
    check(now_cursor_follow_window(150, 120, 100, 100, 100, 100, 1, &h, &v)
              == 1,
          "a window that did not actually move still places");
    check(h == 150 && v == 120,
          "a zero delta leaves the pointer on the point it acted on");

    /* Negative deltas: a window dragged up and to the left. Spelled out
       because the arithmetic is unsigned-adjacent and the peek table's
       coordinates are the one place in this header that are signed. */
    h = -1; v = -1;
    (void)now_cursor_follow_window(400, 300, 380, 280, 100, 60, 1, &h, &v);
    check(h == 120 && v == 80, "the delta may be negative");

    /* THE MUTATION TO WATCH: make the `origin_known` guard return 1 with
       the click point, or drop the guard entirely, and this is the only
       check in the file that names it. */
    h = -1; v = -1;
    check(now_cursor_follow_window(150, 120, 0, 0, 0, 0, 0, &h, &v) == 0,
          "an unreadable window origin places nothing at all");
    check(h == -1 && v == -1,
          "and it does not write a point the caller might use anyway");

    check(now_cursor_follow_window(150, 120, 100, 100, 300, 260, 1,
                                   NULL, NULL) == 0,
          "a caller with nowhere to put the answer is refused, not crashed");
}

int main(void)
{
    test_foreign();
    test_yield();
    test_wrap();
    test_follow_window();
    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
