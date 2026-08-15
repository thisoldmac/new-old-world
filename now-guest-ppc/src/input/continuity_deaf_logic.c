#include "continuity_deaf_logic.h"

#include <stddef.h>

int now_continuity_deaf_verdict(const NowContinuityDeafState *state,
                                unsigned long silence_ticks)
{
    if (state == NULL)
        return kNowContinuityDeafWait;
    if (!state->armed || !state->endpoint_bound)
        return kNowContinuityDeafWait;
    if (state->rebuilt_this_epoch)
        return kNowContinuityDeafWait;
    if (state->delivered_endpoint == 0)
        return kNowContinuityDeafWait;
    if (state->delivered_epoch != 0)
        return kNowContinuityDeafWait;
    if (state->ticks_since_arm < silence_ticks)
        return kNowContinuityDeafWait;
    return kNowContinuityDeafRebuild;
}
