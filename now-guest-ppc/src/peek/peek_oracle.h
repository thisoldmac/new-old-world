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

   V2's second opinion is a second ADDRESS (the stack base), and that
   caps what it can do: a ghost slot whose two addresses both fall
   inside the partition that was reused satisfies every containment
   test there is, and the verdict was Ambiguous - honest, and a refusal.
   V3 carries something that is not an address at all: the process's own
   name, captured in the same context as A5. Memory gets recycled;
   the name does not follow it. Passing the Process Manager's name for
   the partition lets the oracle refute the ghost and resolve the case
   V2 could only refuse.

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

    /* A slot's A5 lands in this partition but something else about it
       contradicts that: its stack base is outside the partition (V2),
       or it carries a different application's name (V3). Either way the
       slot describes a process this partition is not, and it is debris
       rather than a match.

       Each discriminator is only reachable on the format that carries
       it. A V1 table has no second root to disagree with, and a V2
       table has no name; on those formats this verdict is UNREACHABLE
       by construction, which is a degradation to state plainly rather
       than a case to pretend into. Absence of evidence is not
       disagreement, and there is a test for each half. */
    kNowPeekAnchorMismatch,

    /* Two or more slots survive every check. One of them is this
       process and the other is a ghost, and NOTHING AVAILABLE IN THIS
       TABLE'S FORMAT says which - so the read is refused. Picking would
       mean walking a foreign heap on a coin flip, and the whole point
       of the validation layer is that we do not do that.

       The qualifier is load-bearing: this is the verdict each new
       discriminator eats into. A pair of ghosts-in-a-reused-partition
       that V2 could only refuse resolves on V3 when the caller supplies
       a name, because only one of them wears it.  */
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
    /* The slot's captured CurApName, a Pascal string. Empty (name[0]
       == 0) on a pre-V3 table and whenever the extension had no name to
       give - both of which are "cannot tell", not "no name". Copied out
       of the slot inside the seqlock window, never a pointer into the
       table, which the filter may rewrite at any moment. */
    unsigned char name[kNowPeekAnchorNameSize];
} NowPeekAnchorMatch;

/* Resolve the partition [loc, loc+size) to at most one anchor slot.

   `want_name` is the Process Manager's name for the process that owns
   the partition, as a Pascal string, or NULL when the caller has none.
   It is the V3 discriminator, and it is OPTIONAL on purpose: a caller
   that cannot name the process gets exactly the V2 answer rather than
   an error, and NULL is read as "cannot tell", never as "no name".
   The check is skipped entirely unless the table is V3 AND `want_name`
   is a nonempty string AND the slot carries one.

   `now_ticks` is TickCount() in the caller's frame (passed rather than
   read so this stays testable); `max_age_ticks` of 0 disables the age
   gate, and any nonzero value turns an otherwise-Ok match older than it
   into Stale. `out` is always fully initialised, including on the
   verdicts that fill nothing. Returns out->verdict for convenience.
   Reads the table only - no Toolbox, no allocation, no writes. */
NowPeekAnchorVerdict now_peek_anchor_match(const NowPeekTable *table,
                                           unsigned long loc,
                                           unsigned long size,
                                           const unsigned char *want_name,
                                           NowPeekU32 now_ticks,
                                           NowPeekU32 max_age_ticks,
                                           NowPeekAnchorMatch *out);

/* The verdict as a short lowercase word, for the diagnostics surface and
   log lines. Never NULL, never allocates. */
const char *now_peek_anchor_verdict_name(NowPeekAnchorVerdict v);

#endif /* NOW_PEEK_ORACLE_H */
