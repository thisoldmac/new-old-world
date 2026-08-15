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
/* Two bounds, not one - a press edge and a settle-then-release edge are
   different failures wearing the same clock, and 2026-08-15 metal evidence
   (PowerBook 1400c) showed the one-size bound losing on the case that
   actually matters:

   PRESS: latency here is FEEL, not correctness - a slow press just reads as
   a laggy pointer. The Cursor Device record is upstream of the mouse global
   and the propagation is VBL-paced, so a lag that is going to clear clears
   in one or two ticks; four leaves room for a loaded machine and stays
   short enough that a delayed press is imperceptible.

   RELEASE THAT FOLLOWS A SETTLE: the caller is inside the guest's own drag
   loop (a Finder file drop, on the 2026-08-15 record) and what is at stake
   is a real file's location, not feel. The emulator run that calibrated
   the old shared bound of 4 never measured more than 1 tick of wait; the
   1400c routinely exceeds 4, and every excess wait there fell through to
   `expired` at a stale point - the exact defect the barrier exists to
   prevent. Thirty ticks (0.5s) is a deliberately generous bound for that
   one case: a half-second pause inside a drag the user is actively holding
   reads as a mild stutter, while releasing 60px from the settled point
   relocated a real file out of its window on real hardware. Both bounds
   stay FINITE for the same reason: an edge held forever is a stuck drag,
   which is strictly worse than an edge applied at a stale point, so the
   barrier still expires rather than blocking - the release bound is chosen
   for the cost of being wrong, not for a shared "feels fine" number. */
enum { kNowContinuityExposureDeadlineTicksPress = 4 };
enum { kNowContinuityExposureDeadlineTicksRelease = 30 };
/* Enum constants are invisible to the preprocessor, so the asymmetry this
   whole header argues for is pinned with an array-size compile-time assert
   instead of #if: negative array size fails every C compiler this project
   targets, old and new alike. */
typedef char now_continuity_exposure_deadline_asymmetry_holds
    [((int)kNowContinuityExposureDeadlineTicksRelease
      > (int)kNowContinuityExposureDeadlineTicksPress) ? 1 : -1];

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
