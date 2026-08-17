#ifndef NOW_CONTINUITY_DRAGMGR_H
#define NOW_CONTINUITY_DRAGMGR_H

#include <MacTypes.h>

#include "now_continuity_offer.h"

/* The Drag Manager half of the promise drag.
   ------------------------------------------------------------------
   Everything here needs a Macintosh: NewDrag, TrackDrag, the send-data
   UPP, the drop location, an FSSpec. Every question with an ANSWER —
   may this start, how big may it be, what ended it — lives in
   now_continuity_drag.h, which the host cc runs. This file is the
   Toolbox that carries out what that file decided, and it is a
   separate file so a sibling lane working on edge custody
   (continuity_intake.c) and one working on the offer table
   (continuity_offer_intake.c) never meet this one in a merge.

   THE DRAG STARTS FROM AN APPLIED BUTTON, NEVER FROM WIRE ARRIVAL.
   now_continuity_dragmgr_request only ARMS; the arm ripens in
   now_continuity_dragmgr_service, on the resident's own view of the
   button (now_continuity_button_is_down). Starting at wire arrival
   races the apply and tracks nothing — the twin of the session-state
   poisoning the other direction paid eleven metal rounds for.

   THE PROMISE PUMPS. The send-data callback fires inside the Finder's
   drop handling, which is a nested Toolbox loop of somebody else's; the
   bytes for the promised file are pulled through the ordinary transfer
   lane while that loop is suspended, so the callback services the wire
   by hand the whole time (pump.h's rule, in the one place where the
   loop being nested inside is not ours). It is why the size cap exists
   and why it is a refusal rather than a progress bar. */

/* Ask for a drag of whatever continuity.offer is holding out. Arms it;
   the drag itself starts when the applied button says so, or the arm
   expires by name. 0 when armed, -1 with a reason in `err`. */
int now_continuity_dragmgr_request(char *err, long cap);

/* THE EDGE HANDED OFF: a continuity.hostDragBegin arrived. Hold it for
   the next pass of the event loop, where the drag is begun.

   IT DOES NOT ARM, AND IT DOES NOT START HERE. Two different reasons,
   and both are load-bearing:

     - No arm, because the gesture already exists. A person's hand is
       mid-drag on the other machine and the button that steers this
       drag arrives through the Drag Manager's input proc, not through
       the resident's apply. There is nothing to ripen on.

     - Not started HERE, because here is inside the wire. This message
       is dispatched from conn_service, and now_wire_pump() bounces
       every nested entry (wire.c's guard) — so a TrackDrag begun on
       this stack would hold the promise's own pull inside a pump that
       cannot service it. The drop's byte stream would starve against a
       guard that is right. now_continuity_dragmgr_service() runs one
       statement after conn_service in the same loop pass, which costs
       the crossing nothing a person can measure and keeps the promise
       pull on a stack that can pump.

   `item` is the wire's skeleton and a copy is taken. Refusals are made
   when the drag is begun, not here: this call only remembers. A second
   request arriving before the first is served replaces it — the host
   sent it, the host is the authority on its own gesture, and queueing
   two crossings would start a drag for a hand that has already moved
   on. */
void now_continuity_dragmgr_host_request(const NowContinuityOfferItem *item,
                                         unsigned long epoch,
                                         unsigned long drag_seq,
                                         short h, short v);

/* IS A NATIVE DRAG IN FLIGHT RIGHT NOW — the declared state the wire's
   silence and this task's spent time are healthy inside.

   Distinct from `busy` on purpose. `busy` includes an ARMED drag that
   has not started, which is an ordinary application waiting with the
   loop running; this answers the narrower question a liveness monitor
   actually has, which is whether the Drag Manager owns the loop. True
   from TrackDrag's entry to its return, promise included. */
Boolean now_continuity_drag_in_flight(void);

/* Tear it down: an explicit cancel, or escape. Before the drag starts
   this ends the arm outright; once the Drag Manager owns the loop it
   asks, and the ask is honoured at the next pump pass of the streaming
   promise or at TrackDrag's return. 0 when there was something to stop,
   -1 with a reason in `err`. */
int now_continuity_dragmgr_cancel(char *err, long cap);

/* Called each pass of the main event loop. Ripens the arm, and starts
   the real drag when it does. Free when nothing is armed. */
void now_continuity_dragmgr_service(void);

/* The drag's state and last outcome as two words, for the `offer` verb's
   report. Both are non-NULL always. */
void now_continuity_dragmgr_status(const char **state, const char **verdict);

/* True while a drag is armed, tracking or promising — the one question
   another module might reasonably ask. */
Boolean now_continuity_dragmgr_busy(void);

/* The link, or the epoch, went away. An offer cannot outlive the session
   that carried it and neither can a drag of one. */
void now_continuity_dragmgr_forget(void);

/* SLICE-2 DIAGNOSTIC SCAFFOLD, not product. See the mask's meaning in
   continuity_dragmgr.c. Comes out with the block it drives. */
void now_continuity_dragmgr_diag(long mask);

/* Where a bit-16 scripted (input-proc) drag is told to go, in global
   coordinates. Slice-0 spike; comes out with the block it drives. */
void now_continuity_dragmgr_diag_target(short h, short v);

/* Disposes the send-data and input UPPs. Call once at quit. */
void now_continuity_dragmgr_shutdown(void);

#endif /* NOW_CONTINUITY_DRAGMGR_H */
