#ifndef NOW_CONTINUITY_SELECTION_POLL_H
#define NOW_CONTINUITY_SELECTION_POLL_H

#include <Carbon.h>

#include "now_continuity_selection.h"
#include "continuity_service.h"     /* NowContinuityDragIdentity */

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
     - NOT DURING A HELD BUTTON, AND NOTHING ELSE RUNS THEN EITHER.
       The Finder answers Apple Events from its event loop and a drag
       puts it inside the Drag Manager's nested one instead, so a poll
       mid-gesture waits out the whole gesture. Measured on the
       emulator 2026-08-15, the gate is not even the binding
       constraint: through 21 seconds of held drag this application got
       no task time at all — no poll, no wire service, not one log line
       — and every line of the gesture landed in the second the button
       came up. So the selection a single-gesture select-and-drag
       creates CANNOT be published before the release, by any probe;
       what protects the person is that the grab is confirmed against
       the Finder afterwards. docs/open-issues.md carries the
       measurement and what would close the gap.
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

/* How long the ordinary ask waits for the Finder. Two seconds is generous
   for a live Finder and short enough that a wedged one costs a poll rather
   than the connection. Named rather than spelled at the AESend because the
   grab confirmation waits the same amount for the same reason, and a
   second literal is a second thing to get wrong. */
#define kNowSelectionPollTimeoutTicks 120

/* Run one pass. Returns 1 when the table moved and the wire owes the
   host a continuity.selection; 0 for every gated, unchanged or failed
   pass. A failed poll is deliberately indistinguishable from an
   unchanged one HERE — the host is told about the selection, not about
   the Finder's mood — but it is not silent: see the log lines. */
int now_continuity_selection_poll(unsigned long live_epoch);

/* THE DRAG PLANE'S GENERATION, and the reason the gate above is no longer
   the end of the story.

   The paragraph on the held button remains true of the APPLICATION: it
   still gets no task time inside the Finder's drag loop, so no poll can
   see a drag begin. What changed is that something else can. The optional
   resident registers a Drag Manager tracking handler from the dragging
   application's own context and publishes the item at EnterHandler; this
   is where that identity becomes a generation the host may bind.

   Call it from the observer drain with the record it just read. Returns 1
   when a NEW generation exists and the wire owes the host a
   continuity.selection - which the wire learns from the poll's own return
   value, so a drag published between two polls is not held back for a
   cadence it has nothing to do with.

   Everything the poll would have refused, this refuses too: no epoch, no
   generation. A drag observed while nothing is armed is a person using
   their Macintosh. */
int now_continuity_selection_note_drag(const NowContinuityDragIdentity *ident);

/* What the last change published. Never NULL.

   IT IS NOT ALWAYS THE LIVE TABLE. A gesture that crosses the edge is
   drained after the cross has ended its epoch, so its generation is minted
   under the epoch it BEGAN in and published from a table of its own — see
   now_continuity_stub_publish_post_epoch. Ask
   now_continuity_selection_published_after_epoch which one this is; the
   wire must say so on the frame, because a host that could not tell would
   have to read a frame naming a dead epoch as a mistake. */
const NowContinuityStubTable *now_continuity_selection_table(void);

/* Whether the table above names an epoch that has already ENDED. 1 only
   for a post-epoch mint, and only until the next change. */
int now_continuity_selection_published_after_epoch(void);

/* Resolve a grab to a file. Returns a kNowGrab* verdict; `out` is filled
   only on kNowGrabOK. The identity triple is turned back into an FSSpec
   here, so an item renamed or moved since the stub was published fails
   as not-found rather than resolving to whatever now bears the name.

   IT ASKS THE FINDER BEFORE IT ANSWERS. A grab that names a generation the
   guest still holds can still name a file the person stopped holding — that
   is how `hello.txt` crossed the edge on 2026-08-15 while `main.c` was
   being dragged. See now_continuity_grab_confirm. */
int now_continuity_selection_grab(unsigned long live_epoch,
                                  unsigned long epoch,
                                  unsigned long generation,
                                  FSSpec *out);

/* Drop everything, on disconnect or quit. A stub cannot outlive the
   session that consented to it. */
void now_continuity_selection_forget(void);

/* Format the table+hold state into `out` (NUL-terminated, truncated to
   `size`). Carried inside a grab refusal's reason so the HOST log names
   the guest's side of the disagreement without a guest log pull. */
void now_continuity_selection_describe(char *out, unsigned long size);

#endif /* NOW_CONTINUITY_SELECTION_POLL_H */
