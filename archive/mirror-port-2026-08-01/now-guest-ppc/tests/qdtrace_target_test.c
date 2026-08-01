/*
 * qdtrace_target_test.c - which selector `qdtrace start` picked.
 *
 *   cc -Wall -Wextra -Werror -I now-guest-ppc/src/content \
 *      now-guest-ppc/tests/qdtrace_target_test.c \
 *      now-guest-ppc/src/content/qdtrace_target.c \
 *      -o /tmp/t && /tmp/t
 *
 * `now_qdtrace_pick_target` is the one piece of `start`'s new three-way
 * selector (serialHi+serialLo, front, or a raw a5) that has no Toolbox in
 * it, so it is the one piece this file can prove without a Macintosh.
 * RESOLVING a serial or `front` to an A5 - GetFrontProcess,
 * now_ax_bind_process, the anchor oracle's trust gate - lives in
 * qdtrace_cmd.c and has no native test, the same as observe.c's own
 * bind_target: this is the split this codebase already draws between
 * "which" (testable) and "resolve" (Toolbox, unreachable from here).
 *
 * MUTATION-WATCHED: swapping the precedence order (front before serial,
 * or a5 before front) fails testSerialWinsOverFrontAndA5 and
 * testFrontWinsOverA5; dropping the half-serial check entirely fails
 * testHalfASerialIsBadRegardlessOfWhatElseIsSent.
 */

#include "qdtrace_target.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int got, int want, const char *what)
{
    if (got != want) {
        printf("FAIL %s: got %d, want %d\n", what, got, want);
        failures++;
    }
}

static void check_str(const char *got, const char *want, const char *what)
{
    if (strcmp(got, want) != 0) {
        printf("FAIL %s: got \"%s\", want \"%s\"\n", what, got, want);
        failures++;
    }
}

/* ---- the ordinary cases: exactly one selector present ---------------- */

static void test_serial_alone(void)
{
    NowQDTarget t = now_qdtrace_pick_target(0, 1, 1, 0, 0);

    check(t, kNowQDTargetSerial, "serialHi+serialLo alone");
    check_str(now_qdtrace_target_route_name(t), "serial", "its route name");
}

static void test_front_true_alone(void)
{
    NowQDTarget t = now_qdtrace_pick_target(0, 0, 0, 1, 1);

    check(t, kNowQDTargetFront, "front:true alone");
    check_str(now_qdtrace_target_route_name(t), "front", "its route name");
}

static void test_a5_alone(void)
{
    NowQDTarget t = now_qdtrace_pick_target(1, 0, 0, 0, 0);

    check(t, kNowQDTargetA5, "a5 alone");
    check_str(now_qdtrace_target_route_name(t), "a5", "its route name");
}

static void test_nothing(void)
{
    NowQDTarget t = now_qdtrace_pick_target(0, 0, 0, 0, 0);

    check(t, kNowQDTargetNone, "no selector at all");
    check_str(now_qdtrace_target_route_name(t), "", "no route to name");
}

/* front PRESENT but false is not a selector - a caller that said
   front:false explicitly gets the same answer as one who said nothing,
   never treated as "front, sort of". */
static void test_front_false_is_not_a_selector(void)
{
    NowQDTarget t = now_qdtrace_pick_target(0, 0, 0, 1, 0);

    check(t, kNowQDTargetNone, "front:false present is not a selector");
}

/* ---- the refusal: half a serial ---------------------------------------
 *
 * Checked FIRST and unconditionally, mirroring aesend's own rule that
 * half a PSN names a different process rather than none. */

static void test_serial_hi_without_lo_is_bad(void)
{
    check(now_qdtrace_pick_target(0, 1, 0, 0, 0), kNowQDTargetBadSerial,
         "serialHi without serialLo");
}

static void test_serial_lo_without_hi_is_bad(void)
{
    check(now_qdtrace_pick_target(0, 0, 1, 0, 0), kNowQDTargetBadSerial,
         "serialLo without serialHi");
}

/* Found by mutation: a version that checked half-a-serial only when
   nothing else was present let `serialHi` (no `serialLo`) plus `front:
   true` silently resolve via front, hiding the caller's mistake behind
   an answer for a different process than the one it thought it named. */
static void test_half_a_serial_is_bad_regardless_of_what_else_is_sent(void)
{
    check(now_qdtrace_pick_target(1, 1, 0, 1, 1), kNowQDTargetBadSerial,
         "half a serial beside front:true and a5");
}

/* ---- precedence, when more than one selector is present --------------- */

static void test_serial_wins_over_front_and_a5(void)
{
    check(now_qdtrace_pick_target(1, 1, 1, 1, 1), kNowQDTargetSerial,
         "serial, front:true and a5 all present");
}

static void test_front_wins_over_a5(void)
{
    check(now_qdtrace_pick_target(1, 0, 0, 1, 1), kNowQDTargetFront,
         "front:true and a5 both present, no serial");
}

/* front present-but-false must not shadow a5 - the fallback still has to
   be reachable when front was sent and declined. */
static void test_a5_reachable_when_front_is_false(void)
{
    check(now_qdtrace_pick_target(1, 0, 0, 1, 0), kNowQDTargetA5,
         "a5 present, front:false present");
}

int main(void)
{
    test_serial_alone();
    test_front_true_alone();
    test_a5_alone();
    test_nothing();
    test_front_false_is_not_a_selector();
    test_serial_hi_without_lo_is_bad();
    test_serial_lo_without_hi_is_bad();
    test_half_a_serial_is_bad_regardless_of_what_else_is_sent();
    test_serial_wins_over_front_and_a5();
    test_front_wins_over_a5();
    test_a5_reachable_when_front_is_false();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
