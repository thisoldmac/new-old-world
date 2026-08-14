#ifndef NOW_CONTINUITY_SELECTION_POLL_H
#define NOW_CONTINUITY_SELECTION_POLL_H

#include <Carbon.h>

#include "now_continuity_selection.h"

/* Watching what the person at the Macintosh has selected.
   ------------------------------------------------------------------
   One Apple Event to the scriptable Finder ("get selection as alias
   list"), at a bounded cadence, from ordinary task time, and only while
   a Continuity epoch is live. The decisions it feeds — did this change,
   may that grab be served — are in now-guest-shared/src, where the host
   cc watches them; what is here is the Toolbox a test cannot follow.

   THREE GATES, and each exists for a different failure:

     - NO EPOCH, NO POLL. Continuity is the consent; without it this is
       a background process asking the Finder what a person is looking
       at, which is not a thing NOW does.
     - NOT DURING A HELD BUTTON. The Finder answers Apple Events from
       its event loop and a drag puts it inside the Drag Manager's
       nested one instead, so a poll mid-gesture waits out the whole
       gesture. That is precisely the starvation the selection stub
       exists to avoid, arriving by the back door.
     - NOT MORE OFTEN THAN THE CADENCE. An AESend to another process is
       a context switch each way; at the pump's rate it would be
       thousands a minute for an answer that changes when a human
       clicks. */

/* Every 90 ticks — a second and a half.

   Chosen against the measured neighbour rather than picked: the host's
   Mirror cycle already asks this guest for a scene every 0.75 s while
   Continuity is armed (continuity_intake.c), so this is half that rate
   and cannot be the thing that saturates the loop. It is also well
   inside human reaction time between selecting an icon and starting to
   drag it, which is the interval that has to be covered. */
#define kNowSelectionPollTicks 90

/* Run one pass. Returns 1 when the table moved and the wire owes the
   host a continuity.selection; 0 for every gated, unchanged or failed
   pass. A failed poll is deliberately indistinguishable from an
   unchanged one HERE — the host is told about the selection, not about
   the Finder's mood — but it is not silent: see the log lines. */
int now_continuity_selection_poll(unsigned long live_epoch);

/* What the last change published. Never NULL. */
const NowContinuityStubTable *now_continuity_selection_table(void);

/* Resolve a grab to a file. Returns a kNowGrab* verdict; `out` is filled
   only on kNowGrabOK. The identity triple is turned back into an FSSpec
   here, so an item renamed or moved since the stub was published fails
   as not-found rather than resolving to whatever now bears the name. */
int now_continuity_selection_grab(unsigned long live_epoch,
                                  unsigned long epoch,
                                  unsigned long generation,
                                  FSSpec *out);

/* Drop everything, on disconnect or quit. A stub cannot outlive the
   session that consented to it. */
void now_continuity_selection_forget(void);

#endif /* NOW_CONTINUITY_SELECTION_POLL_H */
