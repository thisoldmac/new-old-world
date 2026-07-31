#ifndef NOW_FILES_PULL_H
#define NOW_FILES_PULL_H

/* What a person is told about a file coming down, and when Stop is live.
   ------------------------------------------------------------------
   The defect this exists for: double-clicking a file in the Files pane
   starts a pull that, over MacTCP, takes minutes, and the person at the
   Macintosh had no way to stop it. `now_transfer_cancel` has been on the
   host's projection surface the whole time, so an AGENT could stop it and
   the one party who can see the machine could not. The contract already
   says this is not how it is meant to be (contract/asyncapi.yaml, the
   `cancel` verb: "the PowerPC guest reaches the same capability from its
   own UI and from file.cancel, and declares no verb") - this file is the
   half of "its own UI" that can be reasoned about without a Macintosh.

   PROGRESS COMES FIRST. A Stop button over a pane that says nothing is
   still a person guessing: guessing whether anything is happening, and
   guessing whether pressing it will cost them the file. So the same state
   that arms Stop also produces the line that says what is happening, and
   there is exactly one notion of "a pull is in flight" behind both -
   `now_wire_get_active()`, which the pane already animated a percentage
   from before any of this.

   Toolbox-free on purpose, the way scene_build.c and peek_oracle.c are:
   the wording, the arithmetic and the arming rule are compiled by the
   host cc and watched failing in now-guest-ppc/tests/files_pull_test.c.
   The Macintosh half (a control, a rectangle, a port) stays in
   files_module.c where a test cannot follow it. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef unsigned char Boolean;
#endif

/* A pulled name is a Str31 at most: the sender has already made the name
   one this machine can hold (wire.c get_begin), so 31 + NUL is the whole
   range, not a truncation this file invented. */
#define kPullNameMax 32

typedef enum {
    /* Nothing in flight. */
    kPullIdle = 0,

    /* file.get is on the wire and the other Mac has not answered. No
       bytes exist yet, so there is nothing to say about size - but this
       is emphatically NOT "nothing is happening", and it is the state a
       stalled host leaves a person sitting in for the full 30 s timeout.
       Stop is live here: abandoning a question is as legitimate as
       abandoning an answer. */
    kPullAsking,

    /* Bytes are arriving. */
    kPullReceiving,

    /* Stop was pressed and the teardown has been asked for. Held only
       long enough to be honest about the gap between the press and the
       pane going quiet; the next idle pass resolves it. */
    kPullStopping
} PullPhase;

typedef struct {
    PullPhase phase;
    long received;                    /* bytes written so far */
    long expected;                    /* 0 = the other Mac did not say */
    char name[kPullNameMax];
} PullView;

/* --- the wire's half, which this pane cannot do for itself --------------

   Stopping a pull is two things at once, and doing only one of them is
   worse than doing neither:

     - LOCALLY, abandon the receive and delete the temp. A pull is never
       resumable (wire.c get_begin passes resume_token NULL explicitly),
       so the partial is discarded and no half-written file ever appears
       under the real name.
     - ON THE WIRE, tell the other Mac to stop sending (file.cancel).
       Skipping this leaves the host pushing a file nobody is writing,
       into a lane that is one transfer wide, for the rest of its length.
       The pane would look stopped and the machine would still be busy.

   Both halves live inside wire.c's `g_get`, which is private to it, so
   the primitive is registered here rather than called. Until it is
   registered there is nothing honest a Stop button could do, so it is
   not offered: `now_pull_can_stop` is false and the pane looks exactly
   as it did. A dark button that reports its own absence is not better
   than no button.

   The canceller returns 0 when the transfer was stopped, -1 with a
   reason in `err` when there was nothing to stop or the wire refused. */
typedef int (*NowPullCanceller)(char *err, long cap);

void now_pull_set_canceller(NowPullCanceller fn);
Boolean now_pull_have_canceller(void);

/* --- state -------------------------------------------------------------- */

void now_pull_reset(PullView *v);

/* A file.get has just gone out for `name`. */
void now_pull_asked(PullView *v, const char *name);

/* Fold in what the wire reports. `active` is now_wire_get_active()'s
   answer and the two counts are its out-parameters.

   Asking -> Receiving on the first evidence of an answer, which is the
   only evidence available: `now_wire_get_active` reports pending and
   receiving through one boolean and cannot tell them apart when the
   sender has neither given a size nor delivered a byte. Being briefly
   late into Receiving costs a person nothing (both lines say a fetch is
   underway, both arm Stop); claiming Receiving early would put a
   percentage on a transfer that had not started. */
void now_pull_observe(PullView *v, Boolean active, long received,
                      long expected);

/* Stop was pressed. */
void now_pull_stopping(PullView *v);

/* --- what the person sees ----------------------------------------------- */

/* Whole percent 0..100, or -1 when the size is unknown.

   Not `received * 100 / expected`: that overflows a 32-bit long at 21.5
   MB, and 21.5 MB is an ordinary thing to drag off a Mac. Past the safe
   range both sides drop to K first, which costs a rounding error nobody
   can see in a percentage. */
int now_pull_percent(const PullView *v);

/* The progress line. Never empty while a pull is live, and it always
   names the file - "Getting..." with no name is the pane telling a
   person that something is happening to something. */
void now_pull_note(const PullView *v, char *out, long cap);

/* What is left behind, said out loud. Interruption is a fact to render,
   not a blank: the line names the file, says nothing was kept, and says
   the pane is free again - because "nothing was kept" is the part a
   person cannot check without going to look in the downloads folder. */
void now_pull_stopped_note(const PullView *v, char *out, long cap);

/* Is a Stop control meaningful right now? False without a registered
   canceller, false once Stop has been pressed (a second press has
   nothing left to stop), false when nothing is in flight. */
Boolean now_pull_can_stop(const PullView *v);

/* The repaint gate. Redrawing per chunk over MacTCP is thousands of
   paints for one file; redrawing never is the pane looking hung. The
   step changes once per whole percent when the size is known and once
   per 4 K when it is not, so the caller repaints when this differs from
   what it last drew. Phase is folded in, so entering and leaving a pull
   always repaints even if the count did not move. */
long now_pull_step(const PullView *v);

#endif /* NOW_FILES_PULL_H */
