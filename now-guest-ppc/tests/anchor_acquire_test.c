/*
 * anchor_acquire_test.c - the rationing rules of the acquisition sweep.
 *
 * The sweep's Toolbox half (GetNextProcess, WakeUpProcess, the yield)
 * cannot be run here and is not pretended to be. What IS here is the half
 * that decides who gets woken, who gets WAITED on, and when to stop -
 * which is the half that, got wrong, turns a one-time cost into a stall
 * charged to every scene forever.
 *
 * Each check was watched failing by mutation; the mutation is named
 * beside it, so a reader can reintroduce it and see this file catch it.
 */

#include <stdio.h>

#include "anchor_acquire_logic.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

int main(void)
{
    NowAcquireSeen seen;
    short i;

    now_acquire_seen_reset(&seen, 3);
    check(seen.count == 0, "a fresh session remembers nobody");
    check(!now_acquire_seen_contains(&seen, 0, 5),
          "and therefore owes every process a wake");

    check(now_acquire_seen_add(&seen, 0, 5) == 1, "a silent process is kept");
    check(now_acquire_seen_contains(&seen, 0, 5),
          "and is not waited on a second time");
    /* MUTATION: drop the contains() guard in now_acquire_seen_add and this
       fails - a process re-added on every sweep consumes a slot per sweep
       and the table fills with one PSN. */
    check(now_acquire_seen_add(&seen, 0, 5) == 1 && seen.count == 1,
          "re-adding the same process consumes no second slot");
    check(!now_acquire_seen_contains(&seen, 0, 6),
          "a different PSN with a near-miss low word is a different process");
    check(!now_acquire_seen_contains(&seen, 1, 5),
          "and so is one that differs only in the high word");

    /* Full means full. MUTATION: evict the oldest entry instead of
       refusing, and a machine with more silent processes than slots puts
       one of them back into the WAITING set on every single sweep - which
       is the recurring cost this table exists to bound. */
    for (i = 1; i < (short)kNowAcquireMaxRemembered; ++i) {
        check(now_acquire_seen_add(&seen, 0, (NowPeekU32)(100 + i)) == 1,
              "the table fills to its stated size");
    }
    check(seen.count == (short)kNowAcquireMaxRemembered, "and no further");
    check(now_acquire_seen_add(&seen, 0, 9999) == 0,
          "a full table refuses rather than evicting");
    check(now_acquire_seen_contains(&seen, 0, 5),
          "and the refusal costs no existing entry");

    now_acquire_seen_reset(&seen, 4);
    check(seen.count == 0 && seen.session_epoch == 4,
          "a new writer session owes everyone another wake");

    /* The wait rule. */
    check(!now_acquire_keep_waiting(0, 0, 100, 130),
          "nothing woken is nothing to wait for");
    /* MUTATION: return before the landed>=candidates test and a settled
       machine pays the whole deadline on every scene. */
    check(!now_acquire_keep_waiting(3, 3, 100, 130),
          "all landed leaves at once, deadline or no deadline");
    check(now_acquire_keep_waiting(3, 2, 100, 130),
          "one still missing keeps yielding");
    check(!now_acquire_keep_waiting(3, 2, 130, 130),
          "the deadline arriving is the deadline");
    check(!now_acquire_keep_waiting(3, 2, 131, 130),
          "and having passed it is not a licence to wait forever");
    /* MUTATION: compare `now_ticks < deadline` directly and this fails -
       the ONE case that separates a wrap-safe test from a plausible one.
       mirror_anchor.c was caught by the same shape on 2026-08-07. */
    check(now_acquire_keep_waiting(3, 2, 0xFFFFFFF0UL, 0x0000000EUL),
          "a deadline on the far side of a TickCount wrap is still ahead");
    check(!now_acquire_keep_waiting(3, 2, 0x0000000EUL, 0xFFFFFFF0UL),
          "and one long behind it is still behind");

    /* Null tolerance: these run on a path that must never be the reason a
       machine faults, and the charter's rule is that the component
       degrades rather than takes anything with it. */
    check(!now_acquire_seen_contains(NULL, 0, 1), "no set contains nothing");
    check(now_acquire_seen_add(NULL, 0, 1) == 0, "and remembers nothing");
    now_acquire_seen_reset(NULL, 0);

    if (failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", failures);
        return 1;
    }
    printf("anchor_acquire_test: ok\n");
    return 0;
}
