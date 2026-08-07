/*
 * now_drag_logic.c - the dead-man, and the three other decisions.
 *
 * Compiled into the resident (ext/CMakeLists.txt) and by the host cc for
 * now_drag_logic_test.c. Nothing here touches the Toolbox, allocates,
 * blocks, or reads anything but the cell it is handed and the tick count
 * it is told - because its principal caller is a Time Manager task, and
 * because a rule that can only run at interrupt time on an emulated 68K
 * is a rule nobody ever watches fail.
 */
#include "now_drag_logic.h"

static NowPeekU32 clamp(NowPeekU32 asked, NowPeekU32 lo, NowPeekU32 hi,
                        NowPeekU32 dflt)
{
    /* Zero is the ONE value that means "I did not ask", and it is
       deliberately not the same as "the smallest you allow". A caller
       that left the field unwritten gets the default; a caller that
       asked for something silly gets the nearest thing this resident is
       willing to do. Collapsing the two would make a forgotten field
       silently the most aggressive setting available. */
    if (asked == 0) return dflt;
    if (asked < lo) return lo;
    if (asked > hi) return hi;
    return asked;
}

NowPeekU32 now_drag_clamp_idle(NowPeekU32 asked)
{
    return clamp(asked, (NowPeekU32)kNowPeekDragIdleMinTicks,
                 (NowPeekU32)kNowPeekDragIdleMaxTicks,
                 (NowPeekU32)kNowPeekDragIdleDefaultTicks);
}

NowPeekU32 now_drag_clamp_cap(NowPeekU32 asked)
{
    return clamp(asked, (NowPeekU32)kNowPeekDragCapMinTicks,
                 (NowPeekU32)kNowPeekDragCapMaxTicks,
                 (NowPeekU32)kNowPeekDragCapDefaultTicks);
}

/* TickCount wraps every ~2.3 years of uptime, and a subtraction in
   unsigned arithmetic survives the wrap while a comparison does not.
   `now - then >= limit` is right across the boundary; `now >= then +
   limit` is not. Stated once, used everywhere below. */
static int elapsed_at_least(NowPeekU32 now, NowPeekU32 then, NowPeekU32 limit)
{
    return (NowPeekU32)(now - then) >= limit;
}

/* The later of two tick stamps, by the same wrap-safe rule: b is later
   than a when b - a is a small positive difference rather than a huge
   one. Both stamps come from the same clock, so "huge" means "b is
   actually behind a". */
static NowPeekU32 later_of(NowPeekU32 a, NowPeekU32 b)
{
    return ((NowPeekU32)(b - a) < (NowPeekU32)0x80000000UL) ? b : a;
}

int now_drag_begin(NowPeekDragCell *cell, NowPeekU32 session,
                   NowPeekU32 target_a5, NowPeekI32 h, NowPeekI32 v,
                   NowPeekU32 ticks, NowPeekU32 idle_asked,
                   NowPeekU32 cap_asked)
{
    return now_drag_begin_to(cell, session, target_a5, h, v, ticks,
                             idle_asked, cap_asked, 0, 0, 0);
}

int now_drag_begin_to(NowPeekDragCell *cell, NowPeekU32 session,
                      NowPeekU32 target_a5, NowPeekI32 h, NowPeekI32 v,
                      NowPeekU32 ticks, NowPeekU32 idle_asked,
                      NowPeekU32 cap_asked, int have_to,
                      NowPeekI32 to_h, NowPeekI32 to_v)
{
    if (cell == NULL || session == 0) {
        return 0;
    }
    /* Single-flight: there is one mouse button. A second press while one
       is held is refused rather than queued, because the only thing a
       queue could do here is hold the button down longer. */
    if (cell->state == (NowPeekU32)kNowPeekDragStateHeld) {
        return 0;
    }

    cell->seq++;                        /* odd: a reader must retry */
    cell->state = (NowPeekU32)kNowPeekDragStateHeld;
    cell->session = session;
    cell->target_a5 = target_a5;

    /* THE ONE PLACE A WANT CAN BE PUBLISHED FROM OUTSIDE THE HOST, and
       the only window in which it is possible at all. After this
       function returns, the button is down, the target is in its
       tracking loop, and on a cooperatively-scheduled Macintosh the
       application is not running - so nothing will write want_h again
       until the gesture is over. See now_drag_begin_to's header.

       want_seq 1 with moves_applied 0 is a want the vehicle has not
       consumed, which is exactly the state a dragmove would have left,
       so the tick path below needs no special case and there is one
       implementation of motion rather than two. Without a destination
       the want IS the press point and want_seq stays 0, so nothing is
       consumed and the pointer is not moved twice. */
    cell->want_h = have_to ? to_h : h;
    cell->want_v = have_to ? to_v : v;
    cell->want_seq = have_to ? 1UL : 0UL;
    cell->release_request = 0;
    cell->heartbeat_ticks = ticks;

    cell->at_h = h;
    cell->at_v = v;
    cell->origin_h = h;
    cell->origin_v = v;
    cell->begin_ticks = ticks;
    cell->last_want_ticks = ticks;
    cell->end_reason = (NowPeekU32)kNowPeekDragEndNone;
    cell->end_ticks = 0;
    cell->idle_in_force = now_drag_clamp_idle(idle_asked);
    cell->cap_in_force = now_drag_clamp_cap(cap_asked);
    cell->ticks_served = 0;
    cell->moves_applied = 0;
    cell->pending_mouseup = 0;
    cell->button_down = 1;
    cell->seq++;                        /* even: readable again */
    return 1;
}

int now_drag_request_release(NowPeekDragCell *cell, NowPeekU32 session)
{
    if (cell == NULL || session == 0) {
        return 0;
    }
    if (cell->state != (NowPeekU32)kNowPeekDragStateHeld) {
        return 0;
    }
    /* A release that names a stale session is DROPPED. Without this, a
       release for a gesture that already timed out would end the next
       one - and from the cell alone those two are the same write. */
    if (cell->session != session) {
        return 0;
    }
    cell->release_request = session;
    /* An asked release is also a sign of life, so it refreshes the idle
       clock. It cannot refresh the cap: see the header. */
    return 1;
}

/* The single release path. Every way a drag can end goes through here,
   so that an asked release and a dead-man release cannot diverge - which
   they would, eventually, if there were two of them. */
static int end_session(NowPeekDragCell *cell, NowPeekU32 ticks,
                       NowPeekU32 reason)
{
    cell->seq++;
    cell->state = (NowPeekU32)kNowPeekDragStateEnded;
    cell->end_reason = reason;
    cell->end_ticks = ticks;
    cell->release_request = 0;
    /* The button is up as far as this layer is concerned the instant it
       decides so; the caller's very next act is the low-memory write.
       The EVENT is owed separately and cannot be queued from where this
       runs - see NowPeekDragCell.pending_mouseup. */
    cell->button_down = 0;
    cell->pending_mouseup = 1;
    cell->seq++;
    return kNowDragTickRelease;
}

int now_drag_abandon(NowPeekDragCell *cell, NowPeekU32 ticks)
{
    if (cell == NULL || cell->state != (NowPeekU32)kNowPeekDragStateHeld) {
        return kNowDragTickNothing;
    }
    return end_session(cell, ticks, (NowPeekU32)kNowPeekDragEndSessionLost);
}

int now_drag_tick(NowPeekDragCell *cell, NowPeekU32 ticks)
{
    NowPeekU32 last_life;

    if (cell == NULL || cell->state != (NowPeekU32)kNowPeekDragStateHeld) {
        return kNowDragTickNothing;
    }

    cell->ticks_served++;

    /* ---- the dead-man, FIRST ------------------------------------------
     *
     * Before the release the host asked for, and before any motion. The
     * ordering is the whole point: a tick that must both move and end
     * ends, because a button that stays down is the failure this file
     * exists to prevent and a pixel of motion is not.
     *
     * TWO clocks, and neither can be talked out of firing:
     *
     * - The CAP is measured from begin_ticks and is refreshed by
     *   nothing. A host that heartbeats forever with a wedged idea of
     *   what it is doing still loses the button back. A timeout the
     *   measured thing can refresh measures nothing - which this project
     *   has already paid for once, when a polling probe kept alive the
     *   very silence it was there to detect.
     * - The IDLE clock is measured from the last sign of life, and its
     *   sources are all the HOST's: a new want, a relayed heartbeat, an
     *   asked release. It is deliberately NOT refreshed by this function
     *   running, which is the same mistake wearing different clothes.
     */
    if (elapsed_at_least(ticks, cell->begin_ticks, cell->cap_in_force)) {
        return end_session(cell, ticks,
                           (NowPeekU32)kNowPeekDragEndDeadManCap);
    }
    /* Two sources, both the HOST's: the last want this vehicle consumed,
       and the heartbeat the application relays. Either is a sign the host
       is still there, so the later one wins. */
    last_life = later_of(cell->last_want_ticks, cell->heartbeat_ticks);
    if (elapsed_at_least(ticks, last_life, cell->idle_in_force)) {
        return end_session(cell, ticks,
                           (NowPeekU32)kNowPeekDragEndDeadManIdle);
    }

    /* ---- the release the host asked for -------------------------------- */
    if (cell->release_request != 0) {
        if (cell->release_request == cell->session) {
            return end_session(cell, ticks,
                               (NowPeekU32)kNowPeekDragEndReleased);
        }
        /* A stale nonce. Cleared rather than obeyed, and the session runs
           on - it is not this drag's release and never was. */
        cell->release_request = 0;
    }

    /* ---- motion --------------------------------------------------------
     *
     * Only when want_seq CHANGED. The commit word is what makes a
     * half-written point unconsumable, and acting on want_h/want_v every
     * tick regardless would defeat it: two 32-bit stores are not one
     * write, and the tick can land between them. */
    if (cell->want_seq != 0 && cell->want_seq != cell->moves_applied) {
        cell->seq++;
        cell->at_h = cell->want_h;
        cell->at_v = cell->want_v;
        cell->moves_applied = cell->want_seq;
        cell->last_want_ticks = ticks;
        cell->seq++;
        return kNowDragTickMove;
    }
    return kNowDragTickNothing;
}
