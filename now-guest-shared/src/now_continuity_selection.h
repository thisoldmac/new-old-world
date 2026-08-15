#ifndef NOW_CONTINUITY_SELECTION_H
#define NOW_CONTINUITY_SELECTION_H

/* The Finder-selection stub table, and the two decisions made about it.
   ------------------------------------------------------------------
   A cross-the-edge drag cannot ask the guest anything. The Finder holds
   its own nested Drag Manager loop for the whole gesture, so every fact
   the host needs at cross time has to be on the wire BEFORE the press —
   which is why the guest watches the SELECTION rather than the drag.

   Two decisions come out of that and both are pure arithmetic, so both
   live here where the host cc can watch them fail:

     1. DID THE SELECTION CHANGE? Answered from identity plus the
        modification date, never from contents. The Apple Event poll
        costs a round trip through the Finder and the comparison must
        not cost a second one.
     2. MAY THIS GRAB BE SERVED? A grab names a generation, not a path,
        and the answer is one of a closed set of refusals. Keeping it a
        function rather than a chain of ifs at the wire is what lets the
        refusal cases be watched failing without a Macintosh — and the
        refusals are the half that matters, because a grab bypasses the
        Files share boundary and only these checks stand in its way.

   Toolbox-free on purpose. The Apple Event, the FSSpec and the wire live
   in now-guest-ppc, where a test cannot follow them. */

/* HFS's own limit, plus the NUL. A name that does not fit is not
   truncated here — the poll refuses to build a stub it cannot name. */
#define kNowContinuityStubNameMax 32

typedef struct {
    /* The identity triple. A PATH STRING IS DELIBERATELY ABSENT: two
       mounted volumes may share a name, and the item must still be
       reachable at grab time after a person has renamed a folder above
       it. vRefNum + dirID + name is what the File Manager itself uses. */
    short volume_ref;
    long dir_id;
    char name[kNowContinuityStubNameMax];

    unsigned long file_type;      /* OSType; 0 for a folder */
    unsigned long creator;        /* OSType; 0 for a folder */
    long data_size;
    long rsrc_size;
    unsigned long modified;       /* classic seconds since 1904 */
    int is_folder;
} NowContinuityStubItem;

typedef struct {
    unsigned long epoch;
    unsigned long generation;
    int have_item;
    NowContinuityStubItem item;
} NowContinuityStubTable;

/* Forget everything. Called when an epoch begins or ends: a stub cannot
   outlive the consent it was published under, and leaving one behind is
   the difference between "expired" and "still grantable". */
void now_continuity_stub_reset(NowContinuityStubTable *table,
                               unsigned long epoch);

/* Are these the same item, as far as a drag is concerned? Identity and
   modification date only. Sizes move with the date on any real edit, and
   comparing them as well would make a Finder that touches a date without
   changing bytes look like two different files. */
int now_continuity_stub_same(const NowContinuityStubItem *a,
                             const NowContinuityStubItem *b);

/* Fold in what the poll saw; `item` NULL means nothing is selected.

   Returns 1 when the table moved — a new generation exists and the wire
   owes the host a continuity.selection. Returns 0 when the poll saw what
   the table already held, which is the ordinary case at any useful
   cadence and must cost nothing.

   AN EMPTY SELECTION GETS A GENERATION OF ITS OWN. It is a change like
   any other: the host has to be told to drop what it cached, and telling
   it by silence is indistinguishable from a poll that stopped running. */
int now_continuity_stub_observe(NowContinuityStubTable *table,
                                const NowContinuityStubItem *item);

/* --- the grant that outlives its epoch ------------------------------------

   THE GESTURE ENDS THE EPOCH IT STARTED IN, and that is by design: the
   pointer crossing back to the host is exactly what ends host ownership.
   So the drag a person is still physically holding is, from the guest's
   side, a drag whose epoch is already over — measured on metal 2026-08-14,
   where `selection dropped: the Continuity epoch ended` fired as the
   pointer crossed and every later grab would have been refused bad-epoch
   for a gesture that had not been released yet.

   The rule, stated once here: the LAST generation of an ending epoch stays
   grantable for one in-flight gesture, bounded by a timer and cancelled by
   the next epoch publishing a selection of its own. Everything else about
   consent is unchanged — the item is still the one the person selected with
   their own hand, still exactly one generation, still no path. What expires
   is the window in which it can be redeemed, not the breadth of what it
   names. */

/* How long a grant survives its epoch. A held drag is a human action:
   generous enough for someone to think about where to drop, short enough
   that a forgotten gesture is not a standing grant. Ticks, ~60/second. */
#define kNowContinuityGrantTicks 1800UL

typedef struct {
    unsigned long epoch;          /* 0 when nothing is held */
    unsigned long generation;
    unsigned long expires_at;     /* TickCount() deadline */
    NowContinuityStubItem item;
} NowContinuityGrantHold;

/* Take the ending epoch's final grant out of the dying table.
   A table with no item holds nothing, and holding nothing is recorded as
   nothing rather than as an empty grant. */
void now_continuity_grant_hold(NowContinuityGrantHold *hold,
                               const NowContinuityStubTable *table,
                               unsigned long now_ticks);

/* Drop it: a new epoch published its own selection, the link went away, or
   the gesture was redeemed. */
void now_continuity_grant_release(NowContinuityGrantHold *hold);

enum {
    kNowGrabOK = 0,
    /* The epoch is not the live one — the consent has expired with the
       session that gave it. */
    kNowGrabBadEpoch = 1,
    /* The generation is not the current one. Refused rather than served
       from a history: a person consented to the item they were looking
       at, and the guest keeps no ledger of what they used to be. */
    kNowGrabStaleSelection = 2,
    /* Nothing is selected under the live epoch. */
    kNowGrabNoSelection = 3,
    /* The named item is a folder. The stub says so, so the host can see
       this coming; refusing by name beats serving an empty file. */
    kNowGrabFolderNotYet = 4,
    /* The grant named the last generation of an epoch that has ENDED, and
       its in-flight window has closed. Distinct from bad-epoch on purpose:
       this one says the request was the right shape and arrived too late,
       which is a sentence a person can act on. */
    kNowGrabGrantExpired = 5
};

/* May this grab be served? `live_epoch` is 0 when no epoch is running,
   which is bad-epoch for every generation including the one the table
   happens to still hold. */
int now_continuity_grab_check(const NowContinuityStubTable *table,
                              unsigned long live_epoch,
                              unsigned long asked_epoch,
                              unsigned long asked_generation);

/* The whole decision, live table and held grant together, and the one the
   wire calls.

   `item_out` receives the stub to serve — the table's or the hold's — so
   the caller cannot resolve the wrong one; `after_epoch_out` is set to 1
   when the answer came from the hold, which the caller must say out loud.
   Both are optional. The hold is consulted ONLY where the live check said
   bad-epoch, so nothing about a running epoch changes shape. */
int now_continuity_grab_resolve(const NowContinuityStubTable *table,
                                const NowContinuityGrantHold *hold,
                                unsigned long live_epoch,
                                unsigned long asked_epoch,
                                unsigned long asked_generation,
                                unsigned long now_ticks,
                                const NowContinuityStubItem **item_out,
                                int *after_epoch_out);

/* The refusal's contract code, for the wire. NULL for kNowGrabOK. */
const char *now_continuity_grab_code(int verdict);

#endif /* NOW_CONTINUITY_SELECTION_H */
