/* Native test for the act plane's ABI-selftest reading. Runs on the host:

       cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST -I ../../contract \
          -I ../src/machine mach_selftest_report_test.c \
          ../src/machine/mach_selftest_report.c -o t && ./t

   WHAT IS ACTUALLY BEING WATCHED HERE. The failure this instrument
   exists for is a trap patch whose result lands in the wrong slot: it
   does not crash, it lies, and every counter in the plane reports
   success while the application takes the other branch. So the reading
   must never round a mismatch, a cleared `fired`, or an unreached
   request UP to agreement - and the one case that says "proven" must be
   reachable only from the exact shape the hook writes when it agrees.
   Those are one-line mistakes in C and unobservable on a Macintosh. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "mach_selftest_report.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* The shape act_serve_selftest() writes on the happy path: menu 999,
   item 7, packed the way now_act_menu_answer() packs it. */
#define WANT ((unsigned long)(((999UL & 0xFFFFUL) << 16) | 7UL))

static NowMachSelfTestReading agreed(void)
{
    NowMachSelfTestReading r;

    r.submitted = 0;
    r.plane_error = kNowPeekActErrNone;
    r.fired = 1;
    r.want = WANT;
    r.got = WANT;
    return r;
}

int main(void)
{
    NowMachSelfTestReading r;
    NowPeekActCell         cell;
    int                    i;

    /* --- the one verdict that may claim the convention holds --------- */
    r = agreed();
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestAgreed,
          "answered and read back identically -> agreed");
    check(now_mach_selftest_proves_abi(
              now_mach_selftest_verdict(&r)),
          "agreed is the verdict that proves the ABI");

    /* --- the lie ----------------------------------------------------- */
    r = agreed();
    r.got = WANT ^ 0x00010000UL;        /* answered menu 998, say */
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestAbi,
          "a mismatched high word is an ABI fault");
    r = agreed();
    r.got = WANT & 0xFFFF0000UL;        /* item word lost */
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestAbi,
          "a lost item word is an ABI fault");
    r = agreed();
    r.got = 0;                          /* the classic wrong-slot read */
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestAbi,
          "reading zero out of the result slot is an ABI fault");
    check(!now_mach_selftest_proves_abi(kNowMachSelfTestAbi),
          "an ABI fault never proves the ABI");

    /* The plane may also name it itself, and that must not be
       second-guessed by the equality check. */
    r = agreed();
    r.plane_error = kNowPeekActErrAbi;
    r.got = WANT;                       /* numbers agree; the plane says no */
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestAbi,
          "the plane's own ABI verdict wins over agreeing numbers");

    /* --- not installed versus installed-and-silent ------------------- *
     * Both come back as kNowPeekActErrNoPatch and they are opposite
     * repairs. `want` discriminates because act_serve_selftest() writes
     * it before arming and a refusal never gets that far. */
    r = agreed();
    r.plane_error = kNowPeekActErrNoPatch;
    r.fired = 0;
    r.want = 0;
    r.got = 0;
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestNoPatch,
          "refused before serving (no want written) -> no-patch");
    r = agreed();
    r.plane_error = kNowPeekActErrNoPatch;
    r.fired = 0;
    r.got = 0;                          /* want stays set: the test ran */
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestNotTaken,
          "served, armed, and nothing answered -> not-taken");
    check(!now_mach_selftest_proves_abi(kNowMachSelfTestNoPatch)
              && !now_mach_selftest_proves_abi(kNowMachSelfTestNotTaken),
          "neither no-patch nor not-taken proves anything");

    /* A cleared `fired` with no error at all is not a shape the plane
       produces. It must still not read as agreement. */
    r = agreed();
    r.fired = 0;
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestNotTaken,
          "no error but nothing fired is never agreement");

    /* --- refusals the plane names for itself ------------------------- */
    r = agreed();
    r.plane_error = kNowPeekActErrBadOp;
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestRefused,
          "an unrelated plane error is a refusal, not a fault verdict");

    /* --- never reached ----------------------------------------------- *
     * The client's status is read first: the cell behind a timeout holds
     * the LAST request's numbers, and reading those as this request's
     * answer is exactly how a stale success gets reported. */
    r = agreed();
    r.submitted = 7;                    /* any non-ok NowActStatus */
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestUnreached,
          "a request that never reached the target measures nothing");
    check(!now_mach_selftest_proves_abi(
              now_mach_selftest_verdict(&r)),
          "and it certainly does not prove the ABI");
    check(now_mach_selftest_verdict(NULL) == kNowMachSelfTestUnreached,
          "a NULL reading fails closed");

    /* --- the words --------------------------------------------------- */
    for (i = 0; i <= (int)kNowMachSelfTestUnreached; i++) {
        NowMachSelfTestVerdict v = (NowMachSelfTestVerdict)i;

        check(now_mach_selftest_code(v) != NULL
                  && now_mach_selftest_code(v)[0] != '\0',
              "every declared verdict has a wire code");
        check(now_mach_selftest_message(v) != NULL
                  && strlen(now_mach_selftest_message(v)) > 20,
              "every declared verdict has a sentence");
        check(strcmp(now_mach_selftest_code(v), "unknown") != 0,
              "no declared verdict collapses to unknown");
    }
    check(strcmp(now_mach_selftest_code(kNowMachSelfTestAgreed),
                 now_mach_selftest_code(kNowMachSelfTestAbi)) != 0,
          "agreement and an ABI fault do not share a code");

    /* --- the extraction ---------------------------------------------- *
     * The Toolbox half never picks fields by hand, so the field mapping
     * is exercised here against a cell filled the way the hook fills
     * one. A transposed want/got would make a mismatch read as
     * agreement in exactly one direction and never be seen. */
    memset(&cell, 0, sizeof cell);
    cell.error = kNowPeekActErrNone;
    cell.fired = 1;
    cell.selftest_want = (NowPeekU32)WANT;
    cell.selftest_got = (NowPeekU32)(WANT ^ 1UL);
    now_mach_selftest_read(&cell, 0, &r);
    check(r.want == WANT && r.got == (WANT ^ 1UL),
          "read() keeps want and got apart");
    check(now_mach_selftest_verdict(&r) == kNowMachSelfTestAbi,
          "and the cell it read is judged an ABI fault");
    now_mach_selftest_read(NULL, 0, &r);
    check(r.want == 0 && r.got == 0 && r.fired == 0,
          "read() of no cell leaves nothing of the last one behind");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("mach_selftest_report: all checks passed\n");
    return EXIT_SUCCESS;
}
