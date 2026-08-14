#include "now_continuity_event_match.h"

int now_continuity_match_event(
    const NowPeekU32 *manager_begin_ticks,
    const NowPeekU32 *manager_end_ticks,
    const int *eligible,
    NowPeekU32 count,
    NowPeekU32 observed_ticks)
{
    int best = -1;
    NowPeekU32 best_end = 0;
    NowPeekU32 index;

    for (index = 0; index < count; index++) {
        NowPeekU32 end;

        if (!eligible[index])
            continue;
        end = manager_end_ticks[index];
        if (end > observed_ticks)
            continue;                    /* not yet applied at that tick */
        /* Largest completed manager_end_ticks wins: the most recent
           already-applied edge of this direction. A tie (unobserved in
           practice - two entries would share an apply tick) breaks toward
           the later manager_begin_ticks, keeping the choice deterministic
           without ever needing begin as the primary key. */
        if (best < 0 || end > best_end
                || (end == best_end && manager_begin_ticks[index]
                        > manager_begin_ticks[(NowPeekU32)best])) {
            best = (int)index;
            best_end = end;
        }
    }
    if (best < 0)
        return -1;
    if ((observed_ticks - best_end)
            > (NowPeekU32)kNowContinuityEventMatchSlopTicks)
        return -1;
    return best;
}
