#ifndef NOW_MACH_SELFTEST_REPORT_H
#define NOW_MACH_SELFTEST_REPORT_H

/* The act plane's ABI selftest, read.
   ------------------------------------------------------------------
   The resident plane already SERVES kNowPeekActOpSelfTest (see
   act_serve_selftest() in ext/src/now_ext_act.c and the guard's
   kNowActServeSelfTest verdict). Until this file there was no caller:
   the one instrument that can catch a wrong trap ABI from inside the
   machine was unreachable from the wire.

   WHY IT MATTERS MORE THAN IT LOOKS. A trap patch with the result in the
   wrong slot, or one that does not pop the way the classic Pascal
   convention requires, DOES NOT CRASH - it lies. The patch reports
   firing, every counter on our side says success, and the application
   reads a value that was never the one we wrote and takes the other
   branch. Every other instrument in the plane agrees with the lie,
   because they all read our side of the call. This is the only one that
   reads the CALLER's side: the hook makes a real MenuSelect at a point
   outside the menu bar, answers its own call, and compares what came
   back with what it answered.

   This file is the Toolbox-free half - the verdict and the words. It
   turns (status, cell) into one of a closed set of outcomes, so the
   mapping is watched failing by the host cc in
   now-guest-ppc/tests/mach_selftest_report_test.c rather than discovered
   on a PowerBook. The precedent is peek_oracle.c, scene_build.c and
   now_act_guard.c: the decision is testable, the Toolbox call is not. */

#include "peek_table.h"

typedef enum {
    /* The patch answered and the caller read exactly what it answered.
       The strongest thing this instrument can say, and it is a statement
       about the CALLING CONVENTION only - not about any request. */
    kNowMachSelfTestAgreed = 0,
    /* The patch answered and the caller read something else. THE failure
       this verb exists for: silent everywhere else. */
    kNowMachSelfTestAbi,
    /* The trap was never patched in the target, so nothing answered. A
       different repair from an ABI mismatch and it keeps its own word. */
    kNowMachSelfTestNoPatch,
    /* The hook ran, the patch was there, and `fired` came back clear.
       Answered by the plane as kNowPeekActErrNoPatch too, but reachable
       here as a distinct reading of the same cell, so a caller is never
       told "not installed" about a patch that IS installed. */
    kNowMachSelfTestNotTaken,
    /* The plane refused it for a reason of its own; the cell's `error`
       names which. */
    kNowMachSelfTestRefused,
    /* Never reached the plane: no extension, a stale one, the plane
       dark, no target, no anchor, or the target never pumped. The act
       client's own status vocabulary already names these and this verdict
       defers to it rather than re-spelling them. */
    kNowMachSelfTestUnreached
} NowMachSelfTestVerdict;

/* What the plane came back with, in the two words that decide the
   verdict, plus the numbers a reader needs to see for themselves.

   `submitted` is the act client's NowActStatus as a plain int, so this
   file compiles on a host cc with no Carbon in sight. 0 is kNowActOk;
   any other value is kNowMachSelfTestUnreached and the caller renders
   the client's own sentence for it. */
typedef struct {
    int           submitted;      /* NowActStatus, 0 == ok               */
    unsigned long plane_error;    /* cell->error                          */
    int           fired;          /* cell->fired                          */
    unsigned long want;           /* cell->selftest_want                  */
    unsigned long got;            /* cell->selftest_got                   */
} NowMachSelfTestReading;

/* Read the cell. Pure: no clock, no allocation, no Toolbox. */
NowMachSelfTestVerdict now_mach_selftest_verdict(
    const NowMachSelfTestReading *r);

/* The verdict as a short kebab word for the wire. Never "unknown" for a
   verdict this build declares. */
const char *now_mach_selftest_code(NowMachSelfTestVerdict v);

/* One sentence for a person, naming the failure and the repair rather
   than restating the code. */
const char *now_mach_selftest_message(NowMachSelfTestVerdict v);

/* Does this verdict mean the plane's calling convention is proven on
   this machine, right now? Exactly one verdict does, and a caller that
   wants a boolean must go through here rather than testing == 0 in three
   places. */
int now_mach_selftest_proves_abi(NowMachSelfTestVerdict v);

/* Fill a reading from a cell the plane answered. Split out so the
   Toolbox half never picks fields by hand - and so the test can drive
   the same extraction the application does.

   `submitted` is passed in because it is the client's, not the cell's. */
void now_mach_selftest_read(const NowPeekActCell *cell, int submitted,
                            NowMachSelfTestReading *out);

#endif /* NOW_MACH_SELFTEST_REPORT_H */
