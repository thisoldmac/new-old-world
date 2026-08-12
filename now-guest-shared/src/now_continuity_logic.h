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
NowPeekU32 now_continuity_exit_due(
    NowPeekU32 ticks, NowPeekU32 last_arrival, NowPeekU32 lease,
    int have_physical, int expected_valid,
    NowPeekI32 physical_h, NowPeekI32 physical_v, unsigned physical_buttons,
    NowPeekI32 expected_h, NowPeekI32 expected_v, unsigned expected_buttons);

#endif
