#ifndef NOW_CONTINUITY_DEAF_LOGIC_H
#define NOW_CONTINUITY_DEAF_LOGIC_H

/* WHEN A RETAINED UDP ENDPOINT HAS STOPPED HEARING.

   Continuity keeps one asynchronous Open Transport endpoint for the life of
   the process; continuity_intake.c says why, and the reason is real. What the
   PowerBook showed on 2026-08-15 is the cost of trusting it forever: the host
   application was restarted while the guest stayed up, and from then on every
   epoch armed cleanly, the host sent 107 positions and got zero valid acks,
   and the resident's accepted counter did not move once across five arms.
   Restarting the guest - which is to say, closing and reopening the endpoint -
   cured it immediately.

   This is the predicate that decides to do that one thing deliberately. It is
   separate from the intake so it can be tested on a host compiler, because
   every input it reads is a plain number and the decision is the part that
   must not be wrong: a rebuild that fires too eagerly is precisely the
   close/reopen churn that took OT down twice before. */

enum {
    kNowContinuityDeafWait = 0,
    kNowContinuityDeafRebuild = 1
};

typedef struct {
    int armed;                          /* a live epoch owns the cursor */
    int endpoint_bound;                 /* transport exists to rebuild */
    unsigned long delivered_endpoint;   /* datagrams THIS endpoint ever took */
    unsigned long delivered_epoch;      /* datagrams taken since this arm */
    unsigned long ticks_since_arm;
    int rebuilt_this_epoch;
} NowContinuityDeafState;

/* kNowContinuityDeafRebuild only when every one of these holds:

   - an epoch is armed and an endpoint is bound (otherwise there is nothing
     expecting datagrams, or nothing to rebuild);
   - this endpoint has delivered before. An endpoint that has never delivered
     is not evidence of deafness, it is evidence of a host that has not sent
     anything yet, and rebuilding on it would mean a close/reopen at every
     arm - the churn the retention exists to avoid;
   - this epoch has delivered nothing. One accepted datagram proves the
     endpoint hears, and no watchdog is needed while it does;
   - the silence has lasted `silence_ticks`; and
   - no rebuild has happened in this epoch yet. The recovery is a one-shot,
     so a rebuild that does not help degrades to the status quo rather than
     to a loop of endpoint churn. */
int now_continuity_deaf_verdict(const NowContinuityDeafState *state,
                                unsigned long silence_ticks);

#endif
