/*
 * anchor_acquire_logic.c - see anchor_acquire_logic.h. No Toolbox, so a
 * native test can drive every branch (now-guest-ppc/tests).
 */

#include "anchor_acquire_logic.h"

void now_acquire_seen_reset(NowAcquireSeen *seen, NowPeekU32 session_epoch)
{
    short i;

    if (seen == NULL) {
        return;
    }
    for (i = 0; i < (short)kNowAcquireMaxRemembered; ++i) {
        seen->hi[i] = 0;
        seen->lo[i] = 0;
    }
    seen->count = 0;
    seen->session_epoch = session_epoch;
}

int now_acquire_seen_contains(const NowAcquireSeen *seen,
                              NowPeekU32 hi, NowPeekU32 lo)
{
    short i;

    if (seen == NULL) {
        return 0;
    }
    for (i = 0; i < seen->count; ++i) {
        if (seen->hi[i] == hi && seen->lo[i] == lo) {
            return 1;
        }
    }
    return 0;
}

int now_acquire_seen_add(NowAcquireSeen *seen, NowPeekU32 hi, NowPeekU32 lo)
{
    if (seen == NULL) {
        return 0;
    }
    if (now_acquire_seen_contains(seen, hi, lo)) {
        return 1;
    }
    if (seen->count >= (short)kNowAcquireMaxRemembered) {
        return 0;
    }
    seen->hi[seen->count] = hi;
    seen->lo[seen->count] = lo;
    seen->count++;
    return 1;
}

int now_acquire_keep_waiting(short candidates, short landed,
                             NowPeekU32 now_ticks, NowPeekU32 deadline)
{
    NowPeekU32 remaining;

    if (candidates <= 0) {
        return 0;                     /* nothing was woken; nothing to await */
    }
    if (landed >= candidates) {
        return 0;                     /* all of them answered */
    }
    /* The distance to the deadline in the guest's own word width. Ahead
       is a small positive value; behind wraps to a huge one, which is
       what makes this correct across a TickCount wrap on a 32-bit guest
       AND on the 64-bit machine that runs the native test. Zero is
       "arrived", not "ahead". */
    remaining = (NowPeekU32)(deadline - now_ticks);
    return remaining != 0 && remaining < 0x80000000UL;
}
