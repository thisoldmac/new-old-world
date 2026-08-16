#include "continuity_drain_logic.h"

int now_continuity_drain_stop_has_finisher(const NowContinuityDrainState *state)
{
    if (!state)
        return 0;
    if (!state->notifier_context)
        return 1;                 /* the next event-loop pass resumes */
    return state->task_drain_running != 0;
}

int now_continuity_drain_may_continue(const NowContinuityDrainState *state)
{
    if (!state)
        return 0;
    if (state->consecutive_errors >= (unsigned long)kNowContinuityDrainErrorRetries)
        return 0;
    if (state->iterations >= (unsigned long)kNowContinuityDrainCeiling)
        return 0;
    if (state->iterations >= (unsigned long)kNowContinuityDrainSoftMax
            && now_continuity_drain_stop_has_finisher(state))
        return 0;
    return 1;
}
