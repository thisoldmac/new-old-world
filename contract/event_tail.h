/*
 * event_tail.h - P5, the transition tail: what a poll is too slow to see.
 *
 * THE PROBLEM THIS EXISTS FOR, stated as a measurement rather than a
 * feeling. The host's scene cycle runs at roughly 2.2 s on an emulated
 * G4 - measured 2026-08-05 across 60 cycles: ~783 ms idle, ~92 ms
 * request, ~315 ms decode. Anything that happens and un-happens inside
 * that window is invisible, and no amount of better structure reading
 * fixes it, because the structure is gone by the time anyone looks. An
 * alert raised and dismissed, a window opened and closed, a menu pulled
 * down and released: each leaves the machine exactly as it found it and
 * the Mirror never knew. That is a SAMPLING gap, not a producer gap, and
 * it wants a different instrument.
 *
 * WHAT THIS IS, AND WHAT IT IS NOT. It is a transition sampler running at
 * the frequency of the guest's own event loop, not a trap-level event
 * capture. `now_ext_gne_apply` already runs on every GetNextEvent and
 * WaitNextEvent, in whatever process is pumping, and already reads the
 * window list, the menu list and the current A5 - so a transition it can
 * already SEE costs a comparison and a store. Two consequences worth
 * being plain about:
 *
 *   - it catches what a 2.2 s poll misses because the event loop is
 *     ~60 Hz, not because it hooks anything;
 *   - something raised and dismissed between two event passes is still
 *     missed. That is sub-frame, and the honest claim is "faster
 *     sampling", never "every event".
 *
 * Naming it a tail and shipping a sampler would be the kind of plausible
 * overstatement this project has a rule against, so the name says
 * transition and the claim says sampler.
 *
 * WHY A SEPARATE BLOCK. Exactly the reason `content_block` is one:
 * "a ring in this table would be a ring every reader of every other
 * plane has to carry past" (peek_table.h). One appended word in the
 * table holds the address; the ring lives in the system heap.
 *
 * COST IS THE RISK, and it is worst on the machine that matters. A
 * PowerBook 1400c pumps the same event loop; a filter that allocated, or
 * walked a list, or did anything interesting per pass would tax every
 * application on the machine whether or not anyone was mirroring. So:
 * fixed-size records, a preallocated ring, no allocation after install,
 * and writes only when a watched value CHANGED.
 *
 * OVERFLOW IS REPORTED, NEVER SILENT. `dropped` counts records the ring
 * could not hold. A tail with an unadmitted gap is worse than no tail -
 * the same rule that prints an absent settle as `-` and never `0`.
 */
#ifndef NOW_EVENT_TAIL_H
#define NOW_EVENT_TAIL_H

#include "peek_table.h"

typedef NowPeekU16 NowEventU16;
typedef NowPeekU32 NowEventU32;

enum {
    /* 'NWev'. Written LAST at install, so a reader that finds it can
       trust everything above it - the same commit discipline as the
       content block's magic. */
    kNowEventBlockMagic = (long)NOW_PEEK_4CC('N', 'W', 'e', 'v'),
    kNowEventFormatV1 = 1,
    /* 256 records at 24 bytes is 6 KiB, sized so a burst of window and
       process churn survives one host poll period without dropping. A
       ring that routinely overflows between reads measures its own size
       rather than the machine. */
    kNowEventRingRecords = 256
};

/* What changed. Deliberately coarse: these are the transitions a
   2.2 s poll loses, not a general event log, and a kind nobody consumes
   is a byte every reader carries forever. */
enum {
    kNowEventKindWindowList = 1,  /* the front process's window list head
                                     moved - a window was created,
                                     destroyed or reordered             */
    kNowEventKindFrontProcess = 2,/* the pumping A5 world changed        */
    kNowEventKindMenuList = 3,    /* the menu list changed - a menu was
                                     installed, removed, or tracked     */
    kNowEventKindHeartbeat = 4    /* cadence, so a reader can tell a
                                     quiet machine from a stopped one   */
};

/* One transition. Fixed width on purpose: a ring of fixed records needs
   no size field, cannot wrap mid-record, and a reader steps by
   sizeof(). The content ring carries variable-length draw ops and pays
   for a `size` field; this one has nothing to gain from that. */
typedef struct {
    NowEventU32 ticks;    /* TickCount at the transition                */
    NowEventU32 seq;      /* monotonic; a reader detects loss by gaps   */
    NowEventU32 kind;     /* kNowEventKind*                             */
    NowEventU32 a5;       /* which world was pumping                    */
    NowEventU32 value;    /* the new value of the watched word          */
    NowEventU32 previous; /* what it was, so a reader needs no memory   */
} NowEventRecord;

typedef struct {
    NowEventU32 magic;    /* kNowEventBlockMagic, written LAST          */
    NowEventU16 format;   /* kNowEventFormatV1                          */
    NowEventU16 reserved; /* pairs with format; must be 0               */
    NowEventU32 length;   /* bytes valid; readers gate on >=            */

    /* The application writes these; the extension reads them and writes
       nothing here. Same commit order as the content block: target and
       expiry FIRST, commit LAST; to disarm, clear commit FIRST. */
    NowEventU32 arm_a5;     /* 0 names no target, and names NOTHING -
                               the fail-closed reading, per
                               docs/resident-components.md            */
    NowEventU32 arm_expiry; /* TickCount after which this lapses, so a
                               caller that dies leaves no hook armed   */
    NowEventU32 arm_commit; /* non-zero completes the request          */

    /* The extension writes these. */
    NowEventU32 write_cursor; /* records written, ever; index is
                                 write_cursor % kNowEventRingRecords   */
    NowEventU32 dropped;      /* records the ring could not hold. A
                                 reader that finds this moved knows its
                                 view has a hole, and where.           */
    NowEventU32 passes;       /* event passes seen while armed - the
                                 unguarded counter that separates
                                 "never ran" from "ran and declined"   */
    NowEventU32 last_ticks;   /* when the last record was written      */
    NowEventRecord ring[kNowEventRingRecords];
} NowEventBlock;

/* The layout is shared by three compilers - the 68K extension, the PPC
   application, and the host `cc` for its native test - so it is pinned
   here rather than trusted. Two copies of a shared-memory struct do not
   fail to build when they drift; they fail to AGREE, and that is silent
   corruption (AGENTS.md). */
_Static_assert(sizeof(NowEventRecord) == 24, "event record is 24 bytes");
_Static_assert(offsetof(NowEventBlock, ring) == 40, "ring starts at 40");
_Static_assert(sizeof(NowEventBlock) == 40 + 24 * kNowEventRingRecords,
               "event block is its header plus its ring");

#endif /* NOW_EVENT_TAIL_H */
