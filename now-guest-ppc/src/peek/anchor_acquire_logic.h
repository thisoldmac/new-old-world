#ifndef NOW_ANCHOR_ACQUIRE_LOGIC_H
#define NOW_ANCHOR_ACQUIRE_LOGIC_H

#include "peek_table.h"

/* **The rules of anchor acquisition, with no Macintosh in them.**
 *
 * The defect these serve is stated in docs/open-issues.md: an application
 * acquires an anchor slot only after it has pumped its event loop while
 * the plane was armed, and on a machine nobody has driven, nothing else
 * ever pumps. `WakeUpProcess` is the cure and it lives in
 * anchor_acquire.c; what lives HERE is the bookkeeping that decides who
 * to wake and when to stop waiting, because that is the half a native
 * test can watch fail.
 *
 * One rule shapes all of it: **a process that does not answer a wake must
 * not be waited on twice.** Six faceless background processes on this
 * machine have no event loop at all, and a sweep that waited out its
 * deadline for them would charge every scene the price of the first one
 * forever. So the wake is unconditional and cheap; only the WAIT is
 * rationed, and only first-time candidates ration it. */

/* How many non-answering processes are remembered. One per anchor slot is
   the right size for the same reason the slot table is that size: a
   machine with more live processes than the plane can anchor is already
   past what this component promises. */
enum { kNowAcquireMaxRemembered = kNowPeekMaxAnchors };

/* Processes that were woken and did not answer. NOT a cache of the ones
   that did: a process holding an anchor is never a candidate anyway, and
   if its slot is later recycled it becomes one again and gets a fresh
   wake — which is the behaviour we want and would have to write on
   purpose if this remembered successes instead. */
typedef struct {
    NowPeekU32 hi[kNowAcquireMaxRemembered];
    NowPeekU32 lo[kNowAcquireMaxRemembered];
    short count;
    /* Bookkeeping is per session: a new writer session means a new
       resident view of the machine, and a process that could not answer
       an hour ago is owed another chance rather than a verdict. */
    NowPeekU32 session_epoch;
} NowAcquireSeen;

void now_acquire_seen_reset(NowAcquireSeen *seen, NowPeekU32 session_epoch);

/* 1 when this PSN has already been woken and failed to answer. */
int now_acquire_seen_contains(const NowAcquireSeen *seen,
                              NowPeekU32 hi, NowPeekU32 lo);

/* Remembers a non-answering PSN. Returns 1 if it is now remembered
   (including "already was"), 0 when the table is full — and full means
   full: the OLDEST entry is not evicted, because evicting one puts a
   process that never answers back into the waiting set on the next sweep,
   which is the exact cost this table exists to bound. */
int now_acquire_seen_add(NowAcquireSeen *seen, NowPeekU32 hi, NowPeekU32 lo);

/* **Should the sweep yield again?**
 *
 * Stops the moment every candidate has landed, and otherwise at the
 * deadline. Tick arithmetic is done in NowPeekU32 explicitly: `unsigned
 * long` is 32 bits on the guest and 64 on the machine that runs this
 * test, and a deadline on the far side of a TickCount wrap compares the
 * other way round between the two (the same defect mirror_anchor.c was
 * caught by on 2026-08-07). */
int now_acquire_keep_waiting(short candidates, short landed,
                             NowPeekU32 now_ticks, NowPeekU32 deadline);

/* Has `deadline` arrived or gone by? The bare half of the rule above,
   for the callers that have no candidates to count — the acquisition
   cycle's total budget and each application's turn. One implementation,
   so the two bounded waits on this path cannot disagree about a wrap. */
int now_acquire_deadline_passed(NowPeekU32 now_ticks, NowPeekU32 deadline);

#endif /* NOW_ANCHOR_ACQUIRE_LOGIC_H */
