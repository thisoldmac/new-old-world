/*
 * ot_sched.h - pure decision state for policy-controlled OT send pacing.
 *
 * This module deliberately knows nothing about Open Transport or classic-Mac
 * timers. ot.c owns those mechanisms; this state machine only decides whether
 * a contribution may be attempted and when a monotonic gate is due.
 */
#ifndef TIMBOTTU_OT_SCHED_H
#define TIMBOTTU_OT_SCHED_H

typedef struct {
    unsigned short enabled;
    unsigned short contribution_limit;
    unsigned short burst_contributions;
    unsigned long  resume_us;
    unsigned short rx_drain_lines;
} OTSchedConfig;

typedef struct {
    unsigned short     burst_left;
    unsigned short     flow_blocked;
    unsigned short     gate_armed;
    unsigned long long resume_at;
} OTSchedState;

void otsched_reset(OTSchedState *state, const OTSchedConfig *config);
int  otsched_can_send(const OTSchedState *state,
                      const OTSchedConfig *config);
int  otsched_positive(OTSchedState *state, const OTSchedConfig *config,
                      unsigned long long now, int more_bytes);
void otsched_flow_blocked(OTSchedState *state);
void otsched_flow_ready(OTSchedState *state);
int  otsched_gate_due(const OTSchedState *state, unsigned long long now);
int  otsched_fire_gate(OTSchedState *state, const OTSchedConfig *config,
                       unsigned long long now);

#endif /* TIMBOTTU_OT_SCHED_H */
