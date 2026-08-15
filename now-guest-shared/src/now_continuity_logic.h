#ifndef NOW_CONTINUITY_LOGIC_H
#define NOW_CONTINUITY_LOGIC_H

#include "peek_table.h"

NowPeekU32 now_continuity_accept_rate(NowPeekU32 asked);
NowPeekU32 now_continuity_clamp_lease(NowPeekU32 asked);
NowPeekU32 now_continuity_lease_for_state(NowPeekU32 state,
                                          NowPeekU32 live_lease);
int now_continuity_sequence_newer(NowPeekU32 candidate,
                                  NowPeekU32 previous);
enum {
    kNowContinuityButtonNothing = 0,
    kNowContinuityButtonPress = 1,
    kNowContinuityButtonRelease = 2
};
int now_continuity_button_action(NowPeekU32 applied_generation,
                                 int button_down,
                                 NowPeekU32 incoming_generation,
                                 NowPeekU32 flags);
NowPeekU32 now_continuity_when_rewrite(NowPeekU32 previous_when,
                                       NowPeekU32 event_when,
                                       NowPeekU32 window_ticks,
                                       NowPeekU32 spacing_ticks);
NowPeekU32 now_continuity_release_due(NowPeekU32 applied_generation,
                                      int button_down,
                                      NowPeekU32 previous_generation,
                                      NowPeekU32 previous_flags,
                                      NowPeekU32 current_generation,
                                      NowPeekU32 current_flags);
/* A button edge may not be applied until the position it rides with has been
   EXPOSED to what the guest's own drag loops sample, not merely applied to
   the Cursor Device. See now_continuity_button_barrier. */
enum {
    kNowContinuityBarrierExposed = 0,
    kNowContinuityBarrierWait = 1,
    kNowContinuityBarrierExpired = 2
};
/* Four ticks. The Cursor Device record is upstream of the mouse global and
   the propagation is VBL-paced, so a lag that is going to clear clears in
   one or two; four leaves room for a loaded machine and is still short
   enough that a delayed release is imperceptible. A release held longer
   than this is a worse failure than a release at a stale point, so the
   barrier expires rather than blocking. */
enum { kNowContinuityExposureDeadlineTicks = 4 };

int now_continuity_button_barrier(int have_request, int have_observed,
                                  NowPeekI32 request_h, NowPeekI32 request_v,
                                  NowPeekI32 observed_h, NowPeekI32 observed_v,
                                  NowPeekU32 waited_ticks,
                                  NowPeekU32 deadline_ticks);

NowPeekU32 now_continuity_exit_due(
    NowPeekU32 ticks, NowPeekU32 last_arrival, NowPeekU32 lease,
    int have_physical, int expected_valid,
    NowPeekI32 physical_h, NowPeekI32 physical_v, unsigned physical_buttons,
    NowPeekI32 expected_h, NowPeekI32 expected_v, unsigned expected_buttons);

#endif
