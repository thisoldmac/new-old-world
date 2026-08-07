#ifndef NOW_FRONT_ORDER_H
#define NOW_FRONT_ORDER_H

/* WHICH APPLICATION IS IN FRONT OF WHICH, which the Window Manager
   cannot answer.

   A scene carries every window's `z`, and z is the window's position
   within ITS OWN PROCESS. That is not an oversight: on classic Mac OS
   there is no other kind of window order to read. `WindowList` is a
   low-memory global at 0x9D6 and the Process Manager swaps it on every
   context switch, so each application has its own front-to-back chain
   and no chain links to another's. NOW's whole anchor plane exists
   because of it - the resident INIT captures each process's WindowList
   from inside that process's context, keyed by A5, because that is the
   only place it is visible (contract/peek_table.h, the NowPeekAnchor
   comment; finding `observe-process-local-ui`). There is nothing to
   read across the seam and no API that hands one back.

   So every application's frontmost window reports z == 0, and a
   renderer drawing a scene has never been told which of them is
   actually on top. It came out right often enough to look right: the
   walk emits the front process first, and a picture with one visible
   application in it cannot be wrong. Watched wrong 2026-08-07 in the
   019 integration pair - NOW's sidebar painted over a Finder window the
   guest's own screendump shows in front of it, because after the front
   process the walk falls back to Process Manager enumeration order,
   which is LAUNCH order. Four captures from that run put the same four
   background applications in the same order no matter which had just
   been fronted, which is the measurement that says so.

   WHAT CAN BE KNOWN. Classic Mac OS layers by APPLICATION: bringing one
   forward brings its whole window layer with it, and every window it
   owns is then in front of every window anybody else owns. So the
   cross-application order IS the order the applications were last
   brought to the front - and that is something an application which
   pumps its event loop can WATCH, one `GetFrontProcess` at a time, even
   though it cannot read it.

   That is what this table is. It is not a reading of machine state; it
   is a record of transitions NOW was present for, and the difference
   matters at both ends:

     - A process NOW has seen come to the front has a known rank.
     - A process that was already running before NOW started, and has
       not been fronted since, has NONE - and must be reported as
       unknown rather than given a position. `empty` is a fact about
       the machine, `unknown` is a fact about us (scene.h), and this is
       squarely the second.

   TOOLBOX-FREE ON PURPOSE, like scene_walk.h next door: every entry
   point takes a PSN as two longs and the caller does the one
   `GetFrontProcess`. So the rule that decides what a scene CLAIMS about
   cross-application depth is exercised from a native host test
   (tests/front_order_test.c) replaying a real fronting sequence,
   instead of only from a Macintosh. */

enum {
    /* One slot per process the machine can plausibly be running.
       Matches kNowPeekMaxAnchors, and for the same reason: classic
       systems run a dozen-odd processes and this is headroom. */
    kNowFrontOrderSlots = 32
};

typedef struct {
    unsigned long psn_hi;
    unsigned long psn_lo;
    unsigned long seq;            /* when this process was last fronted */
} NowFrontOrderSlot;

typedef struct {
    NowFrontOrderSlot slots[kNowFrontOrderSlots];
    int           count;
    unsigned long next_seq;       /* 1-based; 0 is "never recorded" */
    unsigned long last_hi;        /* the front PSN as of the last note */
    unsigned long last_lo;
    int           last_known;
    /* HOW MANY WE HAD TO FORGET. The table is bounded, so a machine
       that has run more than kNowFrontOrderSlots applications since
       NOW started has evicted somebody - and a rank that is absent
       because it was evicted must not read as one that was never
       observed. Counted rather than inferred; a consumer that wants
       to know whether this ledger is complete has the number. */
    unsigned long evictions;
} NowFrontOrder;

/* Empties the table. next_seq restarts at 1. */
void now_front_order_reset(NowFrontOrder *o);

/* Records that (psn_hi, psn_lo) is the front process RIGHT NOW.
 *
   Idempotent while the front process does not change, which is what
   makes it affordable to call on every pass of an event loop: a repeat
   of the current front is a compare and a return, and does not burn a
   sequence number or disturb the order.

   Returns nonzero when this call moved the process to the top - i.e.
   when a transition was actually observed. */
int now_front_order_note(NowFrontOrder *o,
                         unsigned long psn_hi, unsigned long psn_lo);

/* The sequence number at which this process was last seen in front, or
   0 if this table has never seen it there.
 *
   HIGHER IS NEARER THE FRONT. A caller ordering applications sorts
   descending on this, and must place every 0 BEHIND every non-zero one
   while saying out loud that their order among themselves is unknown -
   0 is not "the back", it is "we cannot say". */
unsigned long now_front_order_seq(const NowFrontOrder *o,
                                  unsigned long psn_hi, unsigned long psn_lo);

/* Whether every process in a scene could be ranked - i.e. whether the
   ordering this table produced is a claim or a fallback. Counts, so a
   caller can say how much of the scene it covers rather than only
   whether it covers all of it. */
int now_front_order_known_count(const NowFrontOrder *o);

#endif /* NOW_FRONT_ORDER_H */
