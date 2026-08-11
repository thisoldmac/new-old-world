/* The one-act-at-a-time latch, and the interleaving it exists for.
 *
 * WHY THIS TEST EXISTS, and it is not "the latch is two lines".
 * docs/no-hijack-criterion.md §4 states, as part of a written safety
 * argument, that NOW's single act cell is safe because two requests
 * cannot overlap - and says the protection is the guest's threading
 * model, not an interlock. On 2026-08-06 that protection was
 * deliberately spent: `act_yield` now pumps the wire, so the wire CAN
 * dispatch a second act command into the middle of the first. This latch
 * is what replaced it, so it is the one piece of that argument a host cc
 * can still check.
 *
 * WHAT IS MODELLED HERE. The interleaving, not the Toolbox. `act_client.c`
 * includes Carbon and cannot be linked here, so this file plays the two
 * commands' sequence against the same latch object the application uses:
 *
 *     A: cell() -> granted   A: submit -> claim   [A pumps]
 *       B: cell() -> REFUSED, and B writes nothing
 *     A: withdraw -> release
 *     C: cell() -> granted again
 *
 * The load-bearing assertion is not "claim returns 0". It is that the
 * cell B would have written to is UNCHANGED after B has run - because
 * the failure this guards is not a refusal that did not happen, it is an
 * armed request's identity fields being overwritten underneath a live
 * trap patch.
 *
 * WHAT IT CANNOT CHECK: that act_client.c and act_cmds.c actually route
 * through the latch. That is source-shaped and lives in
 * act_inflight_wiring_source_test.py, deliberately as a second test
 * rather than a comment here.
 */

#include <stdio.h>
#include <string.h>

#include "now_act_inflight.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        printf("FAIL: %s\n", what);
        ++failures;
    }
}

/* A stand-in for NowPeekActCell's identity fields - the ones a second
   act would clobber. Deliberately not the contract struct: this test is
   about the sequence, and pulling peek_table.h in would tie it to a
   layout it has no opinion about. */
typedef struct {
    unsigned long control_handle;
    long          arm_point_h;
    long          arm_point_v;
    unsigned long target_a5;
} FakeCell;

static FakeCell g_cell;
static NowActInflight g_latch;

/* now_act_cell()'s shape: the plane's own gate, then the latch. */
static FakeCell *cell_for_a_new_act(int plane_ready)
{
    if (!plane_ready) {
        return NULL;
    }
    if (now_act_inflight_busy(&g_latch)) {
        return NULL;
    }
    return &g_cell;
}

int main(void)
{
    FakeCell *a;
    FakeCell *b;
    FakeCell *c;
    FakeCell  armed;

    memset(&g_latch, 0, sizeof g_latch);
    memset(&g_cell, 0, sizeof g_cell);

    /* --- the resting state ------------------------------------------- */
    check(!now_act_inflight_busy(&g_latch), "a fresh latch is not busy");
    check(now_act_inflight_claims(&g_latch) == 0, "no claims yet");
    check(now_act_inflight_refusals(&g_latch) == 0, "no refusals yet");

    /* --- act A takes the cell and arms -------------------------------- */
    a = cell_for_a_new_act(1);
    check(a != NULL, "an idle plane hands out its cell");
    a->control_handle = 0xCAFE0001UL;
    a->arm_point_h = 84;
    a->arm_point_v = 10;
    a->target_a5 = 0x00112233UL;
    check(now_act_inflight_claim(&g_latch) == 1, "A's submit claims the cell");
    check(now_act_inflight_busy(&g_latch), "the latch is held while A waits");
    armed = g_cell;

    /* --- act B arrives from inside A's pump ---------------------------- */
    b = cell_for_a_new_act(1);
    check(b == NULL, "B is refused the cell while A holds it");
    /* B's own submit would refuse too, if B somehow reached it - that is
       belt and braces, and both are asserted because mach_selftest.c
       reaches submit through a path of its own. */
    check(now_act_inflight_claim(&g_latch) == 0, "a second claim is refused");
    check(now_act_inflight_refusals(&g_latch) == 1, "the refusal is counted");

    /* THE ASSERTION THAT MATTERS. */
    check(memcmp(&armed, &g_cell, sizeof armed) == 0,
          "A's armed identity is untouched after B has been refused");
    check(g_cell.control_handle == 0xCAFE0001UL, "A's handle still stands");
    check(g_cell.arm_point_h == 84 && g_cell.arm_point_v == 10,
          "A's arm point still stands");

    /* A refusal must not disturb the holder's bookkeeping either. */
    check(now_act_inflight_claims(&g_latch) == 1,
          "a refused claim does not count as a claim");
    check(now_act_inflight_busy(&g_latch), "A still holds the cell");

    /* --- A finishes ---------------------------------------------------- */
    now_act_inflight_release(&g_latch);
    check(!now_act_inflight_busy(&g_latch), "withdraw frees the cell");

    /* RELEASE IS IDEMPOTENT, and this is not pedantry: now_act_withdraw()
       is called twice on several act paths (once inside now_act_submit's
       failure exit, once by the verb) and with no matching claim on
       others. A latch that counted pairs would go negative and read busy
       forever, or read free while an act was armed.

       Checked after EACH extra release, not after a pair: a release that
       TOGGLED instead of clearing would pass a check taken after two of
       them and fail only after an odd number. Watched: that mutation
       survived the paired form. */
    now_act_inflight_release(&g_latch);
    check(!now_act_inflight_busy(&g_latch),
          "a second release leaves the latch free");
    now_act_inflight_release(&g_latch);
    check(!now_act_inflight_busy(&g_latch),
          "a third release leaves the latch free");

    /* --- act C, after A ------------------------------------------------ */
    c = cell_for_a_new_act(1);
    check(c != NULL, "the next act gets the cell once A has withdrawn");
    check(now_act_inflight_claim(&g_latch) == 1, "and can claim it");
    check(now_act_inflight_claims(&g_latch) == 2, "two claims granted");
    check(now_act_inflight_refusals(&g_latch) == 1,
          "and exactly one refused, all run");
    now_act_inflight_release(&g_latch);

    /* --- the plane's own gate still comes first ------------------------ */
    check(cell_for_a_new_act(0) == NULL,
          "an unusable plane answers NULL whether or not the latch is free");

    /* --- a NULL latch is never busy and never claimable ----------------- */
    check(now_act_inflight_busy(NULL) == 0, "a NULL latch is not busy");
    check(now_act_inflight_claim(NULL) == 0, "a NULL latch grants nothing");
    now_act_inflight_release(NULL);   /* must not fault */

    if (failures != 0) {
        printf("%d check(s) failed\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
