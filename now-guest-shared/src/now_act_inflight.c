#include "now_act_inflight.h"

#include <stddef.h>               /* NULL, and nothing else */

int now_act_inflight_claim(NowActInflight *state)
{
    if (state == NULL) {
        return 0;
    }
    if (state->armed) {
        /* Counted rather than merely refused. A refusal that leaves no
           trace is indistinguishable from a collision that never
           happened, and the whole reason this latch exists is that the
           protection it replaced was invisible in the code. */
        ++state->refusals;
        return 0;
    }
    state->armed = 1;
    ++state->claims;
    return 1;
}

void now_act_inflight_release(NowActInflight *state)
{
    if (state == NULL) {
        return;
    }
    state->armed = 0;
}

int now_act_inflight_busy(const NowActInflight *state)
{
    return state != NULL && state->armed != 0;
}

unsigned long now_act_inflight_claims(const NowActInflight *state)
{
    return state != NULL ? state->claims : 0UL;
}

unsigned long now_act_inflight_refusals(const NowActInflight *state)
{
    return state != NULL ? state->refusals : 0UL;
}
