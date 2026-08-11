#include "now_continuity_logic.h"

NowPeekU32 now_continuity_accept_rate(NowPeekU32 asked)
{
    if (asked <= 15)
        return 15;
    if (asked <= 30)
        return 30;
    return 60;
}

NowPeekU32 now_continuity_clamp_lease(NowPeekU32 asked)
{
    if (asked < (NowPeekU32)kNowPeekContinuityLeaseMinTicks)
        return (NowPeekU32)kNowPeekContinuityLeaseMinTicks;
    if (asked > (NowPeekU32)kNowPeekContinuityLeaseMaxTicks)
        return (NowPeekU32)kNowPeekContinuityLeaseMaxTicks;
    return asked;
}

NowPeekU32 now_continuity_lease_for_state(NowPeekU32 state,
                                          NowPeekU32 live_lease)
{
    if (state == (NowPeekU32)kNowPeekContinuityStateArmed)
        return (NowPeekU32)kNowPeekContinuityArmGraceTicks;
    return now_continuity_clamp_lease(live_lease);
}

int now_continuity_sequence_newer(NowPeekU32 candidate,
                                  NowPeekU32 previous)
{
    NowPeekU32 distance = candidate - previous;

    /* RFC-1982-style serial arithmetic without an implementation-defined
       unsigned-to-signed conversion at the high bit. Exactly half the
       sequence space is ambiguous and therefore never accepted as newer. */
    return distance != 0 && distance < 0x80000000UL;
}

NowPeekU32 now_continuity_exit_due(
    NowPeekU32 ticks, NowPeekU32 last_arrival, NowPeekU32 lease,
    int have_physical, int expected_valid,
    NowPeekI32 physical_h, NowPeekI32 physical_v, unsigned physical_buttons,
    NowPeekI32 expected_h, NowPeekI32 expected_v, unsigned expected_buttons)
{
    if (have_physical
            && ((expected_valid
                 && (physical_h != expected_h || physical_v != expected_v))
                || physical_buttons != expected_buttons))
        return (NowPeekU32)kNowPeekContinuityExitGuestInput;
    if ((NowPeekU32)(ticks - last_arrival)
            > now_continuity_clamp_lease(lease))
        return (NowPeekU32)kNowPeekContinuityExitLeaseExpired;
    return (NowPeekU32)kNowPeekContinuityExitNone;
}
