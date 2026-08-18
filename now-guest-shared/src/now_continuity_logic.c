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

/* MAY THIS BUTTON EDGE BE APPLIED YET?
 *
 * APPLIED is not EXPOSED. The application moves the pointer through the
 * Cursor Device Manager, whose record is upstream of the mouse global that
 * every guest tracking loop actually samples; the manager call returns
 * before that propagation happens (continuity_cursor.c already counts the
 * lag as after_lag_pending/caught_up). A button transition applied inside
 * that window is dispatched against the point the guest still believes in,
 * not the one this side just requested.
 *
 * It cost a real file. On 2026-08-15 the host did the designed thing for a
 * guest->host drag: settle the held pointer back to the press origin in its
 * own packet, THEN release in the next one. The guest applied both in one
 * service round, the release beat the propagation, and the Finder completed
 * the move at the screen edge where the pointer had crossed rather than at
 * the origin - cosmetic on the desktop, a real relocation out of a window.
 * The host's ordering was never the missing guarantee; the wire is a
 * latest-state mailbox and both packets carried the SAME settled point.
 * What was missing was any barrier between applying that point and acting
 * on it.
 *
 * Answers Exposed (apply now), Wait (poll again), or Expired (apply and say
 * so). Expiry is deliberate: an edge held forever is a stuck drag, which is
 * strictly worse than an edge at a stale point, so the deadline resolves the
 * barrier rather than the barrier resolving the deadline. Unaskable is
 * Exposed - a caller that cannot read the request or the pointer has nothing
 * to wait FOR, and must not turn a missing instrument into a hang. */
int now_continuity_button_barrier(int have_request, int have_observed,
                                  NowPeekI32 request_h, NowPeekI32 request_v,
                                  NowPeekI32 observed_h, NowPeekI32 observed_v,
                                  NowPeekU32 waited_ticks,
                                  NowPeekU32 deadline_ticks)
{
    if (!have_request || !have_observed)
        return kNowContinuityBarrierExposed;
    if (observed_h == request_h && observed_v == request_v)
        return kNowContinuityBarrierExposed;
    if (waited_ticks >= deadline_ticks)
        return kNowContinuityBarrierExpired;
    return kNowContinuityBarrierWait;
}

/* MUST THE EDGE'S OWN POSITION BE APPLIED FIRST?
 *
 * The barrier above asks whether the point this side applied has been
 * exposed. It is only ever answerable if the point this side applied is the
 * point the EDGE RIDES WITH, and on the one path that matters it is not.
 *
 * The resident drives the pointer through low memory at interrupt time while
 * the application is starved inside the target's own drag loop, and says so
 * in its own words: "the final point remains requested below so task time can
 * reconcile the drawn Cursor Device once the release unwinds it". The
 * application's reconcile is gated on the epoch still being ACTIVE - and a
 * cross-edge handoff ends the epoch in the same breath as the release, so the
 * gate declines exactly when the reconcile was promised. The application's
 * last Cursor Device point then stays where the drag loop starved it, early
 * and near the press, while the settled point the host sent lives only in low
 * memory. The Cursor Device record is upstream of low memory, so that stale
 * point is not merely a wrong reading: it is the point the machine will
 * re-assert.
 *
 * Metal, PowerBook 1400c, 2026-08-15 17:19:06: applied=501,446 against
 * exposed=504,451, where 504,451 is EXACTLY the point the host logged as
 * settled. Nothing was rounding and nothing was lagging - the barrier was
 * holding an edge against a point no longer on the wire, and spent its whole
 * half-second deadline doing it.
 *
 * Never against the human's own hand: a guest-input exit means somebody
 * touched the trackpad, and moving the pointer back for the sake of a tidy
 * release would take the machine off them. */
int now_continuity_settle_before_edge(NowPeekU32 exit_reason,
                                      int have_edge, int position_valid,
                                      int applied_valid,
                                      NowPeekI32 request_h,
                                      NowPeekI32 request_v,
                                      NowPeekI32 applied_h,
                                      NowPeekI32 applied_v)
{
    if (!have_edge || !position_valid)
        return 0;
    if (exit_reason == (NowPeekU32)kNowPeekContinuityExitGuestInput)
        return 0;
    if (!applied_valid)
        return 1;
    return applied_h != request_h || applied_v != request_v;
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
