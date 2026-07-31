#ifndef NOW_PEEK_ORACLE_H
#define NOW_PEEK_ORACLE_H

#include "peek_table.h"

/* Which anchor slot belongs to a given process - and, when the honest
   answer is "I cannot tell", saying so instead of picking one.

   The extension publishes anchors keyed by A5 and never fills PSN (it
   runs at interrupt-ish time in a foreign context and may not call the
   Process Manager). Correlating an anchor to a process is therefore the
   application's job, and it is done by CONTAINMENT: the slot whose A5
   lies inside the process's partition is that process's slot.

   Containment is not proof. A partition is megabytes wide and A5 is one
   32-bit value, so a recycled slot left behind by a dead process whose
   memory was reused can land inside a live partition and look exactly
   like a match. Until the V2 anchor format there was no second opinion
   available, and the reader took the first match it found.

   This layer is the second opinion. It answers with a verdict rather
   than a pointer, because three of the five answers are cases where
   returning a pointer would be a lie.

   Deliberately free of Toolbox calls: it takes the partition bounds as
   arguments rather than asking the Process Manager for them. That keeps
   the impure half (which process, which partition) in peek_read.c and
   makes every verdict below reachable from a native test on the host,
   with no Macintosh in the loop. */

typedef enum {
    /* Exactly one slot claims this partition and survives every check
       available in the table's format. */
    kNowPeekAnchorOk = 0,

    /* No slot's A5 lies in this partition. The ordinary resting state
       for a process that has not pumped its event loop since the plane
       was armed - faceless background apps can sit here forever. */
    kNowPeekAnchorNotFound,

    /* A slot's A5 lands in this partition but its stack base does not,
       so the two roots describe different address spaces and the slot
       is stale debris rather than this process. Only reachable on a V2
       table; a V1 table has no second root to disagree with, which is a
       degradation to state plainly rather than a case to pretend into.  */
    kNowPeekAnchorMismatch,

    /* Two or more slots survive every check. One of them is this
       process and the other is a ghost, and NOTHING in the table says
       which - so the read is refused. Picking would mean walking a
       foreign heap on a coin flip, and the whole point of the
       validation layer is that we do not do that.  */
    kNowPeekAnchorAmbiguous,

    /* One clean match, last captured longer ago than the caller's
       window. REPORTED, NOT REFUSED: window state is only ever as fresh
       as the target's last event-loop pass, so every reader here holds
       a snapshot and a clock cannot change that. The match's fields are
       filled exactly as for Ok. Only ever returned when the caller
       passes a nonzero max_age_ticks; the default is no age gate at
       all, which is the rule peek_read.c has always followed. */
    kNowPeekAnchorStale
} NowPeekAnchorVerdict;

typedef struct {
    NowPeekAnchorVerdict verdict;
    short slot;                   /* matching index; -1 when none */
    /* Filled on Ok and Stale only. Ambiguous and Mismatch leave these
       zero on purpose - there is no honest value to put in them. */
    NowPeekU32 stamp_ticks;
    NowPeekU32 age_ticks;         /* now_ticks - stamp_ticks */
    NowPeekU32 a5;
    NowPeekU32 window_list;
    NowPeekU32 menu_list;
    NowPeekU32 stack_base;        /* 0 on a V1 table */
} NowPeekAnchorMatch;

/* Resolve the partition [loc, loc+size) to at most one anchor slot.
   `now_ticks` is TickCount() in the caller's frame (passed rather than
   read so this stays testable); `max_age_ticks` of 0 disables the age
   gate, and any nonzero value turns an otherwise-Ok match older than it
   into Stale. `out` is always fully initialised, including on the
   verdicts that fill nothing. Returns out->verdict for convenience.
   Reads the table only - no Toolbox, no allocation, no writes. */
NowPeekAnchorVerdict now_peek_anchor_match(const NowPeekTable *table,
                                           unsigned long loc,
                                           unsigned long size,
                                           NowPeekU32 now_ticks,
                                           NowPeekU32 max_age_ticks,
                                           NowPeekAnchorMatch *out);

/* The verdict as a short lowercase word, for the diagnostics surface and
   log lines. Never NULL, never allocates. */
const char *now_peek_anchor_verdict_name(NowPeekAnchorVerdict v);

#endif /* NOW_PEEK_ORACLE_H */
