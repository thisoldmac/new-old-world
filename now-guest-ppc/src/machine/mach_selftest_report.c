/* The act plane's ABI selftest, read. See mach_selftest_report.h. */

#include "mach_selftest_report.h"

void now_mach_selftest_read(const NowPeekActCell *cell, int submitted,
                            NowMachSelfTestReading *out)
{
    if (out == NULL) {
        return;
    }
    out->submitted = submitted;
    out->plane_error = 0;
    out->fired = 0;
    out->want = 0;
    out->got = 0;
    if (cell == NULL) {
        return;
    }
    out->plane_error = (unsigned long)cell->error;
    out->fired = cell->fired ? 1 : 0;
    out->want = (unsigned long)cell->selftest_want;
    out->got = (unsigned long)cell->selftest_got;
}

NowMachSelfTestVerdict now_mach_selftest_verdict(
    const NowMachSelfTestReading *r)
{
    if (r == NULL) {
        return kNowMachSelfTestUnreached;
    }
    /* The client's status is read FIRST and it is not a detail: a
       request that never reached the target has no cell worth reading,
       and the fields in it are the last request's. */
    if (r->submitted != 0) {
        return kNowMachSelfTestUnreached;
    }

    switch (r->plane_error) {
    case kNowPeekActErrAbi:
        return kNowMachSelfTestAbi;
    case kNowPeekActErrNoPatch:
        /* The plane answers kNowPeekActErrNoPatch for both "the trap was
           never patched" (refused before serving, `fired` clear and the
           want/got pair never written) and "served, and the patch did
           not answer". They are different repairs - install the
           extension versus find out why an installed patch declined - so
           they are read apart here rather than collapsed.

           `want` is the discriminator and it is a fact of the serve
           path: act_serve_selftest() writes selftest_want BEFORE it
           arms, so a nonzero want proves the hook got as far as running
           the test. A refusal in now_act_serve_begin() never touches
           it. */
        return r->want != 0 ? kNowMachSelfTestNotTaken
                            : kNowMachSelfTestNoPatch;
    case kNowPeekActErrNone:
        break;
    default:
        return kNowMachSelfTestRefused;
    }

    /* No error, so the hook ran the test to the end. Agreement is still
       checked HERE rather than trusted: the plane's own equality test
       and this one reading the same two numbers is the point - an
       instrument that only reports its own verdict cannot be audited.
       A cleared `fired` with no error is not a shape the plane produces;
       it is read as not-taken rather than as agreement, because the one
       thing this file must never do is say "proven" about a call that
       never happened. */
    if (!r->fired) {
        return kNowMachSelfTestNotTaken;
    }
    if (r->got != r->want) {
        return kNowMachSelfTestAbi;
    }
    return kNowMachSelfTestAgreed;
}

const char *now_mach_selftest_code(NowMachSelfTestVerdict v)
{
    switch (v) {
    case kNowMachSelfTestAgreed:    return "abi-agreed";
    case kNowMachSelfTestAbi:       return "act-abi";
    case kNowMachSelfTestNoPatch:   return "act-no-patch";
    case kNowMachSelfTestNotTaken:  return "act-not-taken";
    case kNowMachSelfTestRefused:   return "act-refused";
    case kNowMachSelfTestUnreached: return "act-unreached";
    default:                        break;
    }
    return "act-unreached";
}

const char *now_mach_selftest_message(NowMachSelfTestVerdict v)
{
    switch (v) {
    case kNowMachSelfTestAgreed:
        return "the patch answered and the application read exactly what "
               "it answered: the trap calling convention holds in that "
               "process on this machine";
    case kNowMachSelfTestAbi:
        return "the patch answered and the application read something "
               "else - the Pascal result slot or the callee-pops "
               "contract is wrong, which is the failure that reports "
               "success everywhere else";
    case kNowMachSelfTestNoPatch:
        return "the MenuSelect patch is not installed in that process, "
               "so nothing answered; install or re-arm the plane rather "
               "than reading this as an ABI fault";
    case kNowMachSelfTestNotTaken:
        return "the patch is installed and did not answer the call the "
               "test made itself; that is a guard or an install problem, "
               "not a calling-convention one";
    case kNowMachSelfTestRefused:
        return "the resident plane refused the request and named why in "
               "its own error";
    case kNowMachSelfTestUnreached:
        return "the request never reached the target process, so nothing "
               "about the calling convention was measured";
    default:
        break;
    }
    return "the request never reached the target process, so nothing "
           "about the calling convention was measured";
}

int now_mach_selftest_proves_abi(NowMachSelfTestVerdict v)
{
    return v == kNowMachSelfTestAgreed;
}
