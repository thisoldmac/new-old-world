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

int now_continuity_button_action(NowPeekU32 applied_generation,
                                 int button_down,
                                 NowPeekU32 incoming_generation,
                                 NowPeekU32 flags)
{
    int wants_down;

    if (!now_continuity_sequence_newer(incoming_generation,
                                       applied_generation))
        return kNowContinuityButtonNothing;
    wants_down = (flags & (NowPeekU32)kNowPeekContinuityPrimaryDown) != 0;
    if (wants_down && !button_down)
        return kNowContinuityButtonPress;
    if (!wants_down && button_down)
        return kNowContinuityButtonRelease;
    return kNowContinuityButtonNothing;
}

/* Compress a synthetic mouse event's `when` toward its predecessor so any
   consumer's click-pairing arithmetic accepts the pair. Finder compares
   against a PRIVATE copy of the double-click time - a 56-tick pair failed
   under an active 60-tick window - so widening the global cannot reach it;
   the interval itself has to shrink. Returns the rewritten when, or 0 when
   no rewrite applies: no predecessor, outside the window (the caller
   resets its chain), or already at least as tight as the target - a when
   must never move forward in time. */
NowPeekU32 now_continuity_when_rewrite(NowPeekU32 previous_when,
                                       NowPeekU32 event_when,
                                       NowPeekU32 window_ticks,
                                       NowPeekU32 spacing_ticks)
{
    NowPeekU32 gap = event_when - previous_when;

    if (previous_when == 0 || gap >= window_ticks)
        return 0;
    if (gap <= spacing_ticks)
        return 0;
    return previous_when + spacing_ticks;
}

/* The interrupt-time release must see an up wherever it sits in the v4
   edge pair. Under rapid clicking the packet's current edge is already
   the NEXT press by the time the bounded timer looks, and the release
   the machine needs most is in the previous slot - previously visible
   only to task time, which the press's own target starves. Returns the
   generation to release with, newest first, or 0 when nothing is due. */
NowPeekU32 now_continuity_release_due(NowPeekU32 applied_generation,
                                      int button_down,
                                      NowPeekU32 previous_generation,
                                      NowPeekU32 previous_flags,
                                      NowPeekU32 current_generation,
                                      NowPeekU32 current_flags)
{
    if (now_continuity_button_action(applied_generation, button_down,
                                     current_generation, current_flags)
            == kNowContinuityButtonRelease)
        return current_generation;
    if (now_continuity_button_action(applied_generation, button_down,
                                     previous_generation, previous_flags)
            == kNowContinuityButtonRelease)
        return previous_generation;
    return 0;
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
