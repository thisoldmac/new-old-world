#ifndef NOW_CONTINUITY_DRAIN_LOGIC_H
#define NOW_CONTINUITY_DRAIN_LOGIC_H

/* HOW FAR A SINGLE DRAIN OF THE UDP ENDPOINT IS ALLOWED TO GO.

   T_DATA is edge-triggered: Open Transport delivers exactly one, and no
   further one until the client has read the endpoint down to kOTNoDataErr.
   continuity_intake.c already says that, and the wedge fix of 2026-08-15
   already handed the residue to a task-time poll from the event pumps.

   What 2026-08-16 paid for is the case where task time NEVER COMES. Inside a
   foreign application's held-button nested loop - OS 9 menu tracking is the
   one a person meets - NOW's cooperative context does not run at all. Only
   the OT notifier (deferred task level) and the resident (interrupt level)
   still execute. So during exactly the interval where the deferred recovery
   was the whole safety net, the safety net is unreachable.

   The consequence was not a dropped packet. `arrival_ticks` froze while the
   host was alive and sending 0.5s keepalives; the resident's ~1.5s lease
   expired; the held button was released into the foreign menu and selected an
   item the person never chose (metal, 2026-08-16: it launched Internet
   Explorer from a menu that was merely open).

   Hence the distinction this header exists to make. A drain may stop early
   only when SOMEBODY ELSE IS GUARANTEED TO FINISH IT - which is a property of
   the calling context, not of the endpoint:

   - Task time may always stop early. The next event-loop pass resumes from
     the owed flag, and that pass is guaranteed because task time is running.
   - The notifier may stop early only while a task-time drain is already in
     the loop; it is preemptible by the notifier but not the reverse, so that
     loop will read what this pass left.
   - Otherwise the notifier must drain to quiet, because nothing else will.

   THE INTERRUPT BUDGET, which is the reason a cap existed at all. A state
   datagram is NOW_CONTINUITY_STATE_BYTES (48) on the wire and decodes into a
   fixed-size struct; accepting one is one OTRcvUData into a preallocated
   64-byte buffer, one bounded decode, and ~15 word stores into the shared
   cell. There is no allocation, no logging, no Toolbox call and no send on
   this path. The ceiling below therefore buys a bounded worst case measured
   in low milliseconds of deferred-task time, and it is only ever approached
   when the application has already been starved for longer than that - the
   host sends 60 Hz positions, so a backlog of hundreds means seconds of
   silence. The alternative that the cap of 8 actually bought was an endpoint
   deaf for the whole hold. That is not a cheaper outcome, it is the defect.

   Every input here is a plain number so the decision can be watched failing
   on a host compiler, the way continuity_deaf_logic.h is. */

enum {
    /* What one ordinary pass takes when a return is guaranteed. Unchanged
       from the value the wedge fix shipped: with task time running, a burst
       longer than this is better finished on the next pass than in the
       notifier. */
    kNowContinuityDrainSoftMax = 8,
    /* The bound when nothing else will finish the job. Larger than any
       backlog a live 60 Hz sender can build inside one nested loop that a
       person holds open, and small enough to stay a bounded stretch of
       deferred-task time. */
    kNowContinuityDrainCeiling = 512,
    /* Consecutive receives answering something this endpoint does not expect.
       Retrying a few times covers a transient; spinning on a permanent one is
       the hazard the original "do not spin" comment named, so the count is
       small and any successful read clears it. */
    kNowContinuityDrainErrorRetries = 4
};

typedef struct {
    /* Nonzero when this drain is running at OT notifier time. */
    int notifier_context;
    /* Nonzero when a task-time drain is already inside the loop. It will read
       whatever this pass leaves, which is what makes an early stop safe. */
    int task_drain_running;
    /* Receives attempted in this drain so far, malformed ones included: the
       cost being bounded is the receive, not the acceptance. */
    unsigned long iterations;
    /* Consecutive receives that answered an error this endpoint does not
       expect, reset by any successful read. */
    unsigned long consecutive_errors;
} NowContinuityDrainState;

/* Nonzero when the loop may attempt another receive.

   Returns 0 when the error budget is spent, when the ceiling is reached, or
   when the soft cap is reached AND the context has a guaranteed finisher. It
   deliberately does NOT return 0 at the soft cap in a notifier with no
   task-time drain running: that early stop is the freeze. */
int now_continuity_drain_may_continue(const NowContinuityDrainState *state);

/* Nonzero when a drain that stopped in this context left the endpoint's
   recovery to somebody. Used to separate the two ways a drain can end owing
   work - a handoff, which is normal, from a ceiling or error exit in a
   notifier with no finisher, which is the starvation shape and is worth a
   counter of its own. */
int now_continuity_drain_stop_has_finisher(const NowContinuityDrainState *state);

#endif
