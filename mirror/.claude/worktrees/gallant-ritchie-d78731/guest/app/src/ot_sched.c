/* ot_sched.c - see ot_sched.h. */
#include "ot_sched.h"

void otsched_reset(OTSchedState *state, const OTSchedConfig *config)
{
    state->burst_left = config->enabled ? config->burst_contributions : 0;
    state->flow_blocked = 0;
    state->gate_armed = 0;
    state->resume_at = 0;
}

int otsched_can_send(const OTSchedState *state,
                     const OTSchedConfig *config)
{
    if (!config->enabled) {
        return 1;
    }
    return !state->flow_blocked && !state->gate_armed
        && state->burst_left > 0;
}

int otsched_positive(OTSchedState *state, const OTSchedConfig *config,
                     unsigned long long now, int more_bytes)
{
    if (!config->enabled || state->burst_left == 0) {
        return 0;
    }
    state->burst_left--;
    if (more_bytes && state->burst_left == 0) {
        state->gate_armed = 1;
        state->resume_at = now + config->resume_us;
        return 1;
    }
    return 0;
}

void otsched_flow_blocked(OTSchedState *state)
{
    state->flow_blocked = 1;
}

void otsched_flow_ready(OTSchedState *state)
{
    state->flow_blocked = 0;
}

int otsched_gate_due(const OTSchedState *state, unsigned long long now)
{
    /* Signed modular subtraction keeps a short deadline valid across the
     * 64-bit monotonic counter's wrap boundary. */
    return state->gate_armed
        && (long long)(now - state->resume_at) >= 0;
}

int otsched_fire_gate(OTSchedState *state, const OTSchedConfig *config,
                      unsigned long long now)
{
    if (!config->enabled || !otsched_gate_due(state, now)) {
        return 0;
    }
    state->gate_armed = 0;
    state->resume_at = 0;
    state->burst_left = config->burst_contributions;
    return 1;
}
