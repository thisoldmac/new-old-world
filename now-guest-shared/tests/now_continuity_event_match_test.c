#define NOW_PEEK_TABLE_HOST 1
#include <stdio.h>

#include "now_continuity_event_match.h"

#define CHECK(value) do { if (!(value)) {                              \
    fprintf(stderr, "continuity event match failed at line %d\n",      \
            __LINE__);                                                 \
    return 1;                                                          \
} } while (0)

int main(void)
{
    /* Metal evidence, 2026-08-13 223137.log, epoch 10: three pending up
       entries (gen 116/117/118) with only gen 116 and 118 shown in the
       excerpt. Reconstructed windows: gen 116 applies [55340,55346], a
       later gen 117 applies around [55400,55420], and gen 118 applies
       around [56800,56850]. An event observed at 55501 is ~155 ticks after
       gen 116's apply and belongs to whichever entry completed most
       recently by then - gen 117, not the older gen 116 that "first
       unmatched" picked. */
    {
        NowPeekU32 begin[3] = { 55340, 55400, 56800 };
        NowPeekU32 end[3]   = { 55346, 55420, 56850 };
        int eligible[3] = { 1, 1, 1 };

        /* Only gen 116 has completed by 55350: too early for 117 or 118. */
        CHECK(now_continuity_match_event(begin, end, eligible, 3, 55350)
              == 0);
        /* By 55501 gen 117 has also completed and is the newest applied
           edge still <= the observed tick - this is the case the old
           first-unmatched matcher got wrong (it would have picked index 0,
           the ~140-160 tick stale gen 116 entry, because that is what
           "first eligible" finds first). */
        CHECK(now_continuity_match_event(begin, end, eligible, 3, 55501)
              == 1);
        /* By 56900 all three have completed; gen 118 is newest. */
        CHECK(now_continuity_match_event(begin, end, eligible, 3, 56900)
              == 2);
    }

    /* Eligibility is the caller's job (direction/fill/seqlock already
       filtered): an ineligible candidate is invisible to the matcher even
       when its window would otherwise win. */
    {
        NowPeekU32 begin[2] = { 100, 200 };
        NowPeekU32 end[2]   = { 110, 210 };
        int eligible[2] = { 1, 0 };

        CHECK(now_continuity_match_event(begin, end, eligible, 2, 300) == 0);
    }

    /* Refuse rather than guess: observed tick precedes every candidate's
       completed apply (and therefore precedes every candidate's
       manager_begin_ticks too, since begin never exceeds end). */
    {
        NowPeekU32 begin[2] = { 500, 600 };
        NowPeekU32 end[2]   = { 520, 630 };
        int eligible[2] = { 1, 1 };

        CHECK(now_continuity_match_event(begin, end, eligible, 2, 100)
              == -1);
        CHECK(now_continuity_match_event(begin, end, eligible, 2, 519)
              == -1);
        /* Right at the boundary of the earlier window, that window wins. */
        CHECK(now_continuity_match_event(begin, end, eligible, 2, 520) == 0);
    }

    /* Refuse when the only completed candidate is stale beyond the slop
       constant: an event that far removed from every applied edge is not
       plausibly ours. Exactly at the boundary still matches. */
    {
        NowPeekU32 begin[1] = { 1000 };
        NowPeekU32 end[1]   = { 1000 };
        int eligible[1] = { 1 };
        NowPeekU32 boundary =
            1000u + (NowPeekU32)kNowContinuityEventMatchSlopTicks;

        CHECK(now_continuity_match_event(begin, end, eligible, 1, boundary)
              == 0);
        CHECK(now_continuity_match_event(begin, end, eligible, 1,
                                         boundary + 1) == -1);
    }

    /* No eligible candidates at all: refuse. */
    {
        NowPeekU32 begin[1] = { 10 };
        NowPeekU32 end[1]   = { 10 };
        int eligible[1] = { 0 };

        CHECK(now_continuity_match_event(begin, end, eligible, 1, 50)
              == -1);
    }
    CHECK(now_continuity_match_event(NULL, NULL, NULL, 0, 50) == -1);

    return 0;
}
