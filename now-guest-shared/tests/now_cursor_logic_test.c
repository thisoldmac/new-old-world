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
    check(now_cursor_is_foreign(100, 100, 100, 100) == 0,
          "a pointer exactly where we left it is ours");
    check(now_cursor_is_foreign(101, 100, 100, 100) == 1,
          "one pixel of horizontal drift is somebody else");
    check(now_cursor_is_foreign(100, 101, 100, 100) == 1,
          "one pixel of VERTICAL drift is somebody else too");
    /* Mutation watched: comparing only h. A mouse pushed straight up or
       down is the most ordinary human motion there is, and a plane that
       only notices horizontal movement would fight exactly that. */
    check(now_cursor_is_foreign(0, 0, 0, 0) == 0,
          "the origin is not special - a pointer at 0,0 we placed is ours");
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

int main(void)
{
    test_foreign();
    test_yield();
    test_wrap();
    if (failures) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
