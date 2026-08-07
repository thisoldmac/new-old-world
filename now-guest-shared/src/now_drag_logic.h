/*
 * now_drag_logic.h - P7's decision layer, with no Toolbox in it.
 *
 * The drag vehicle is a Time Manager task in the resident (ext/src/
 * now_ext_drag.c). Almost nothing it does is a decision: it writes four
 * low-memory globals and re-primes itself. The decisions - has the
 * dead-man expired, is this want new, does this release name the session
 * that is actually running - are HERE, so the host cc can compile them
 * and `scripts/test-native` can drive them without a Macintosh.
 *
 * That split is not tidiness. The dead-man is the one rule in this plane
 * whose failure ends with a machine holding the mouse button down, and a
 * rule that can only be exercised at interrupt time on an emulated 68K
 * is a rule nobody watches fail. Everything below is a pure function of
 * the cell and a tick count.
 *
 * THE ONE THING THAT IS NOT HERE is the release itself. now_drag_tick
 * decides; the caller acts. A decision layer that could not be called
 * from a Time Manager task would be the wrong shape, and one that wrote
 * low memory could not be tested at all.
 */
#ifndef NOW_DRAG_LOGIC_H
#define NOW_DRAG_LOGIC_H

#include "peek_table.h"

#ifdef __cplusplus
extern "C" {
#endif

/* What the vehicle must do this tick. Ordered by urgency rather than by
   frequency: a tick that must both move and release releases, because a
   button that stays down is the failure this whole file exists for. */
enum {
    kNowDragTickNothing = 0,
    /* at_h/at_v have been updated; write them to the mouse globals. */
    kNowDragTickMove = 1,
    /* end_reason is set; write the button UP. Not optional, not
       deferrable, and not conditional on anything the caller knows. */
    kNowDragTickRelease = 2
};

/* Clamp what a caller asked for into the range the RESIDENT owns.
   Exported because the clamped value is reported back (idle_in_force /
   cap_in_force) and a test must be able to state the expected number
   without restating the arithmetic - a limit stated twice is the defect
   class this project has paid for most. */
NowPeekU32 now_drag_clamp_idle(NowPeekU32 asked);
NowPeekU32 now_drag_clamp_cap(NowPeekU32 asked);

/* Take a cell from Idle (or Ended) to Held. Returns 0 and touches
   nothing if a drag is already running - single-flight, because there is
   one mouse button.

   `session` must be non-zero: zero is the "no session" value that
   release_request compares against, so a session numbered 0 could be
   ended by a caller that named nothing. */
int now_drag_begin(NowPeekDragCell *cell, NowPeekU32 session,
                   NowPeekU32 target_a5, NowPeekI32 h, NowPeekI32 v,
                   NowPeekU32 ticks, NowPeekU32 idle_asked,
                   NowPeekU32 cap_asked);

/* One tick of the vehicle. Returns a kNowDragTick* and updates the cell
   in place. Safe to call on an idle cell, on a NULL cell, and after the
   session has ended - a Time Manager task that had to be careful about
   when it fired would be the wrong vehicle. */
int now_drag_tick(NowPeekDragCell *cell, NowPeekU32 ticks);

/* The host asked. Recorded rather than obeyed: the tick performs it, so
   that an asked release and a dead-man release travel exactly one code
   path and cannot diverge. Returns 0 if the nonce names no live
   session. */
int now_drag_request_release(NowPeekDragCell *cell, NowPeekU32 session);

/* The plane was disarmed, or the writer lease changed under the
   session. The button still goes up - see kNowPeekDragEndSessionLost -
   but the gesture is never reported as completed. Returns a
   kNowDragTick*, so the caller's release path is again the only one. */
int now_drag_abandon(NowPeekDragCell *cell, NowPeekU32 ticks);

#ifdef __cplusplus
}
#endif

#endif /* NOW_DRAG_LOGIC_H */
