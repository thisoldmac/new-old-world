#ifndef NOW_CONTINUITY_EVENT_MATCH_H
#define NOW_CONTINUITY_EVENT_MATCH_H

#include "peek_table.h"

/* An observed synthetic mouse event is claimed by the most recently
   COMPLETED button-timing entry of the same direction: the eligible
   candidate whose manager_end_ticks is the LARGEST value still <= the
   observed tick. That is the only entry the event can honestly belong to -
   anything with a later manager_end_ticks had not yet been applied when the
   event was queued, and anything with a smaller manager_end_ticks belonged
   to an earlier press whose own event should already have been matched to
   it. Matching "first eligible of the same direction" instead (the prior
   behaviour) pairs a later event with an older, already-superseded entry
   whenever several edges are pending - misattributing exactly when clicks
   come fast enough for the columns to matter (2026-08-13 metal evidence:
   gen 116 matched an event ~140 ticks after its own manager apply; gen 118
   was off by ~1400 ticks).

   Refuses to match (returns -1) when the observed tick precedes every
   eligible candidate's completed apply - nothing yet applied is old enough
   to explain the event, which also covers "precedes every candidate's
   manager_begin_ticks" since a candidate's begin can never exceed its own
   end - and when the chosen candidate's manager_end_ticks is more than
   kNowContinuityEventMatchSlopTicks behind the observed tick, because an
   event that stale is not plausibly a report of that apply and guessing
   would misattribute across presses rather than merely misorder within
   one. */
enum {
    /* ~10 seconds of guest ticks - the same order of magnitude as
       kNowPeekContinuityLeaseMaxTicks (contract/peek_table.h). An event
       this far behind the last completed apply has already crossed
       multiple plausible epoch/press boundaries, so leaving it unmatched
       is more honest than a distant guess. */
    kNowContinuityEventMatchSlopTicks = 600
};

/* manager_begin_ticks/manager_end_ticks are parallel arrays indexed
   [0, count). eligible[i] must be nonzero only for entries the caller has
   already confirmed are of the observed direction, not yet filled with an
   observation, and stable to read (its own seqlock/parity check is storage
   this pure function does not see, so it stays the caller's job). Returns
   the index of the chosen candidate, or -1 when none qualifies. */
int now_continuity_match_event(
    const NowPeekU32 *manager_begin_ticks,
    const NowPeekU32 *manager_end_ticks,
    const int *eligible,
    NowPeekU32 count,
    NowPeekU32 observed_ticks);

#endif
