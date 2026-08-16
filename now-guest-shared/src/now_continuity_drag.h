#ifndef NOW_CONTINUITY_DRAG_H
#define NOW_CONTINUITY_DRAG_H

#include "now_continuity_offer.h"

/* The promise drag's decisions, with no Drag Manager in them.
   ------------------------------------------------------------------
   A person (or the host) asks this Macintosh to pick up what
   continuity.offer is holding out and DRAG it — a real Drag Manager
   drag carrying flavorTypePromiseHFS, dropped wherever the classic
   Finder is told to drop it. now_continuity_dragmgr.c in the PowerPC
   guest owns NewDrag/TrackDrag/SetDragItemFlavorData and nothing else;
   every question with an answer worth watching fail lives here, where
   the host cc runs it.

   Four such questions, and each one has already been named as a hazard
   in the slice-2 brief:

     - WHEN MAY THE DRAG START. Not when the wire says so. The Drag
       Manager tracks a button, and the button on this side is the
       SYNTHETIC one the resident applies from the host's plane. A drag
       started at wire-arrival races the apply and tracks nothing — the
       apply-race twin of the session-state poisoning that cost the
       other direction eleven metal rounds. So a request ARMS, and the
       arm ripens only on an applied button-down (see
       now_continuity_button_is_down, which reads the resident's own
       view rather than Button()). An arm that never ripens refuses by
       name rather than hanging.

     - HOW BIG MAY IT BE. The promise callback fires INSIDE the
       Finder's drop handling. Streaming there is a nested Toolbox loop
       that must pump the wire the whole time, and the honest v1 answer
       to "what if it is enormous" is a refusal with a name, not a
       progress bar nobody can see. kNowContinuityDragPromiseCapBytes
       below is that line. Background-fill after the promise hands back
       a reference is legal under promised HFS and is deliberately NOT
       built here: a fork still filling is a lie shaped like a file
       until something marks it busy, and marking it is a later slice.

     - WHAT COUNTS AS ENDING. Classic Finder is unforgiving of a drag
       that never ends. Cancel, escape, a drop the Finder declined and
       a promise that failed mid-stream are four different ways to
       arrive at the same requirement: the state returns to Idle and
       says which one happened.

     - WHETHER TWO MAY OVERLAP. They may not, and the refusal is
       `busy`. One drag at a time is also the file lane's own rule
       (wire.c refuses a second transfer), so a second arm accepted
       here would only be refused one layer down with a worse word.

   Toolbox-free by construction, like now_continuity_offer.h beside it:
   no FSSpec, no DragRef, no ticks source of its own — the caller passes
   the clock in, so a test can move it. */

/* THE SIZE LINE, STATED ONCE.

   Both forks stream through the same lane, so the cap is against their
   sum, not against either alone.

   Where the number comes from. The lane was measured at roughly
   100 KB/s on metal, and the promise must finish inside the Finder's
   drop handling with the wire pumped by hand throughout. One megabyte
   is about ten seconds there: comfortably inside the file lane's own
   30-second silence timeout (wire.c's kGetTimeoutTicks) and inside the
   host's 75-second idle bound (pump.h), with room for a slow link
   before either fires. It is also a size a 68030 with 8 MB can host
   without the streaming buffer becoming the constraint, which is the
   ceiling the host→guest plan asks the PowerPC side to state here so
   the 68K port inherits ONE number rather than picking a second one.

   Raising it is a decision about how long a person's Finder may sit
   inside a drop, and it is made here or nowhere. */
#define kNowContinuityDragPromiseCapBytes 1048576L

/* How long an arm waits for the applied button before giving up, in
   ticks.

   Two seconds. The measured apply cadence on this plane is 48-72 ticks
   between applies (continuity_intake.c records the 2026-08-13
   measurement), so 120 ticks is several applies' worth of grace — long
   enough that a slow apply is not mistaken for an absent one, short
   enough that a console `offer --drag` typed with no host gesture
   behind it answers in the time a person waits for a prompt rather
   than looking wedged. */
#define kNowContinuityDragArmTicks 120L

enum {
    /* Nothing in flight. */
    kNowDragIdle = 0,
    /* Asked for; waiting on an applied button-down to ripen. */
    kNowDragWaitingButton = 1,
    /* TrackDrag is running. The wire is stalled for its duration, the
       same documented stall as DragWindow and MenuSelect — a human
       holding the mouse, not an unbounded wait. */
    kNowDragTracking = 2,
    /* The send-data proc is streaming inside the Finder's drop. */
    kNowDragPromising = 3
};

enum {
    kNowDragOK = 0,
    /* Nothing is being held out under the live epoch. */
    kNowDragNoOffer = 1,
    /* The offer is a folder; the file lane serves one file, and an
       empty folder is a lie shaped like a transfer (the same refusal
       now_wire_get_offer already makes locally). */
    kNowDragFolder = 2,
    /* Over kNowContinuityDragPromiseCapBytes. */
    kNowDragTooLarge = 3,
    /* Another drag is already armed, tracking or promising. */
    kNowDragBusy = 4,
    /* Armed, and the applied button never came within the arm window. */
    kNowDragButtonNeverCame = 5,
    /* The Drag Manager itself refused to start. */
    kNowDragDragFailed = 6,
    /* Bytes stopped, or the lane refused, mid-promise. */
    kNowDragTransferFailed = 7,
    /* Torn down deliberately: escape, an explicit cancel, or a drop the
       Finder declined. */
    kNowDragCancelled = 8,
    /* A cancel arrived with nothing to cancel. */
    kNowDragNotDragging = 9,
    /* The Finder took the drop and never asked for the promise. Not a
       failure of ours, and it is named rather than folded into
       `cancelled` because the two want different diagnosis: one is a
       person changing their mind, the other is a receiver that does not
       speak promised HFS. */
    kNowDragPromiseNeverAsked = 10,
    /* TrackDrag ended without a drop AND this machine's own Button() was
       up when it began. The drag tracked a button that existed only on
       our plane.

       WHY THIS IS ITS OWN WORD. The first live guest run of this slice
       (2026-08-15) logged `cancelled (TrackDrag -128)` and nobody could
       say from that whether a person had let go, whether the Finder had
       declined the drop, or whether TrackDrag had never had a button to
       track at all - three different defects wearing one word. The
       applied button the arm ripens on and the button the Drag Manager
       tracks are two different questions, and this verdict exists
       because reading them as one produced a result that could not be
       attributed. It reports absence and defect separately, which is the
       standing rule for anything that reads a live machine. */
    kNowDragButtonNotReal = 11
};

/* What an arm ripening asks the caller to do. */
enum {
    kNowDragTickWait = 0,     /* nothing yet */
    kNowDragTickStart = 1,    /* button is applied down: start TrackDrag */
    kNowDragTickExpire = 2    /* the arm window ran out */
};

typedef struct {
    int state;                 /* one of the kNowDrag* states */
    /* The identity the drag renders and the promise materialises. A
       COPY, taken at arm time on purpose: the offer table is the host's
       to rewrite at any moment, and a drag whose name changed halfway
       through is a drag that materialises something the person did not
       pick up. */
    NowContinuityOfferItem item;
    unsigned long epoch;
    unsigned long generation;
    unsigned long armed_at;    /* ticks, as the caller counts them */
    /* Set by a cancel that arrived while the Drag Manager owned the
       loop. The streaming promise reads it each pump pass; nothing else
       can interrupt a nested Toolbox loop from outside. */
    int cancel_requested;
    /* Did the promise get asked for at all during this drag. */
    int promise_asked;
    /* Did it complete. */
    int promise_settled;
    /* How the last drag ended, one of the kNowDrag* verdicts.
       kNowDragOK means it settled. */
    int last_verdict;
} NowContinuityDragState;

void now_continuity_drag_reset(NowContinuityDragState *st);

/* Is this size servable inside a promise? Both forks, summed. Split out
   from request() so the size policy can be watched fail on its own,
   without an offer table around it. */
int now_continuity_drag_size_ok(const NowContinuityOfferItem *item);

/* Ask for a drag of whatever `table` holds under `live_epoch`.
   kNowDragOK arms it (state becomes WaitingButton); anything else
   refuses and leaves the state alone — a refusal must not disturb a
   drag already in flight, which is the whole reason `busy` exists. */
int now_continuity_drag_request(NowContinuityDragState *st,
                                const NowContinuityOfferTable *table,
                                unsigned long live_epoch,
                                unsigned long now_ticks);

/* Ripen the arm. `button_down` is the APPLIED button, never Button().
   Returns one of the kNowDragTick* actions; Start moves the state to
   Tracking, Expire returns it to Idle with kNowDragButtonNeverCame. */
int now_continuity_drag_tick(NowContinuityDragState *st, int button_down,
                             unsigned long now_ticks);

/* The Drag Manager refused to start after all. Back to Idle, named. */
void now_continuity_drag_start_failed(NowContinuityDragState *st);

/* The send-data proc fired. Returns 1 when it should stream, 0 when it
   must refuse — which is what a cancel that landed between the drop and
   the callback looks like from in here. */
int now_continuity_drag_promise_begin(NowContinuityDragState *st);

/* Streaming finished. `ok` non-zero means a file exists at the drop
   location and its flavor data can be handed back. */
void now_continuity_drag_promise_end(NowContinuityDragState *st, int ok);

/* Should the streaming loop give up on its next pump pass? True once a
   cancel has been requested — the only way into a nested Toolbox loop
   from outside it. */
int now_continuity_drag_should_abort(const NowContinuityDragState *st);

/* TrackDrag returned. Back to Idle either way; the verdict distinguishes
   settled, declined, never-asked, cancelled and a button that was never
   the machine's. Returns it.

   `toolbox_button_at_start` is Button() - THIS MACHINE'S OWN VIEW -
   sampled immediately before TrackDrag was called. It is deliberately a
   different artifact from the applied button the arm ripened on
   (now_continuity_button_is_down, the resident's shared cell): the two
   answer different questions, and only asking both separates "a person
   let go" from "the Drag Manager was handed a button this Mac never
   had". Pass 1 when the caller genuinely cannot sample it; that keeps
   the old verdicts and claims nothing. */
int now_continuity_drag_ended(NowContinuityDragState *st, int track_ok,
                              int toolbox_button_at_start);

/* Tear it down. Before the button ripens this ends it outright; once the
   Drag Manager owns the loop it can only ask, and the ask is honoured at
   the next promise pump pass or at TrackDrag's return. Returns
   kNowDragOK when there was something to cancel. */
int now_continuity_drag_cancel(NowContinuityDragState *st);

/* The link went away, or the epoch did. Unconditional: an offer cannot
   outlive its session and neither can a drag of one. */
void now_continuity_drag_forget(NowContinuityDragState *st);

/* One word per verdict, for a refusal a person reads and a test
   matches. Never NULL. */
const char *now_continuity_drag_code(int verdict);

/* One word per state, same rule. */
const char *now_continuity_drag_state_name(int state);

#endif /* NOW_CONTINUITY_DRAG_H */
