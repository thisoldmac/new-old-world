#ifndef NOW_QDTRACE_H
#define NOW_QDTRACE_H

/* qdtrace - the reader for the content plane (P3).
   ------------------------------------------------------------------
   The plane produces a ring; this drains it. ext/src/now_content.c is
   the WRITER - resident 68K code that runs at draw time inside an armed
   application - and contract/content_table.h is the layout the two
   halves agree on. Everything here is on the application side of that
   contract: it reads what the writer left, and it writes exactly four
   words (the arm request) in exactly one order.

   NOTHING HERE HAS RUN ON A MACINTOSH. Neither has the plane it reads.
   Upstream (timbottu/mirror, `verb_qdtrace`) shipped a count-only M0 and
   never passed the milestone that would have exercised a ring, so the
   record path is code that has run nowhere on either side. The decode is
   Toolbox-free for that reason, the way peek_oracle.c and
   now_content_logic.c are: a ring decoder must be executable without a
   Macintosh or it has no gate at all.

   WHAT THE SUBCOMMANDS ANSWER, which is the design and not a menu:

     status   "is anything drawing at all, and at whom?" Counters, the
              arm cells, ring occupancy against a cursor. It moves NOT ONE
              RECORD. Upstream's M0 was count-only and was useful on its
              own; a reader that cannot answer this without a drain has
              made the cheap question expensive.
     start    arm one A5 world, for a bounded time, in one of two modes.
     stop     disarm.
     drain    read records from a cursor, and say precisely why the answer
              ended where it did.

   IS A DRAIN A TRANSFER OR A BOUNDED CONTROL ANSWER? A bounded control
   answer, and the reasoning is not "it fits" - it does not; a busy ring
   is 64 KiB against a 4096-byte control cap.

   docs/streaming-a-scene.md settled the neighbouring case the other way
   and the distinction is the whole argument. A scene is a TREE: its parts
   mean something only reassembled, it changes between pages, and a
   reassembled scene is "a picture of no single moment" - which is why a
   scene is a transfer. A ring is a LOG. Every record is self-contained,
   carries its own `port` and `ticks`, and is ordered; the writer already
   maintains the resume point (`write_cursor`) that pagination would
   otherwise have to invent; and the records a drain did not reach are
   still in the ring, not lost by being unread. A prefix of a log is a
   complete answer about a shorter interval - it is not a fragment of a
   whole.

   So the 4096-byte cap is a PACING parameter here rather than an
   obstacle, and the price of that is the one this file pays in full:
   a short answer must say why it is short. Four different reasons end a
   drain, and they are four different words on the wire (`more`,
   `resync`, `torn`, `busy`), because "fewer records than you expected"
   silently covering an overrun is exactly the quiet machine.

   The second reason not to make it a transfer: a transfer takes the lane,
   and the lane is one wide. A drain is the thing an agent does in a loop
   while watching an application draw. Holding the one transfer lane in a
   loop, to move a payload that has a natural resume point, would buy
   nothing and cost every file operation for the duration. */

#include "content_table.h"

/* ---- reading a ring while its writer is live ------------------------

   The writer is resident code inside every process that pumps events, so
   it is never "stopped" in any sense this reader controls. What
   content_table.h actually guarantees, and all it guarantees:

     - ONE writer. Classic Mac OS is cooperative; one application draws
       at a time, and now_content_ring_put is the ring's only writer.
     - A SEQLOCK. `seq` is bumped to odd before a record is committed and
       to even after. Odd means a commit is in flight RIGHT NOW.
     - `write_cursor` is a MONOTONIC byte count, not a position. Position
       is `write_cursor % ring_cap`. Records below `write_cursor` are
       complete.
     - Records are 2-aligned and NEVER wrapped mid-record; a WRAP record
       pads the tail.
     - The tail invariant the port added: after every put, the bytes left
       at the ring's end are either zero or a whole header. Upstream's
       ring could advance its cursor past a tail too short to hold a
       header, and a record-stepping reader reads such a tail AS a header
       - one stale v2 header whose `size` decides where it goes
       next. That defect is fixed in the writer; this reader still
       validates every `size` it steps by, because a reader that trusts
       the writer's invariant has no defence when the writer is a
       different build than it was compiled against.

   What it does NOT guarantee, and what this reader therefore does:

     - The seqlock covers ONE record commit, not a whole read. So the
       drain samples `seq` before and after: unchanged means no writer
       touched the ring for the duration, and the decode stands. Changed
       means a writer committed while we walked - which is only a problem
       if it LAPPED the window we were reading, and that is decidable
       exactly, by re-reading `write_cursor` and asking whether the
       distance from our start cursor now exceeds the ring's capacity.
       Lapped is `torn` and the answer is discarded rather than shipped;
       not lapped is a valid answer about bytes the writer has since
       moved past but not yet overwritten.
     - Odd `seq` on entry is `busy`. It is not an error and it is not
       retried in a loop here - one commit is bounded and the caller can
       simply call again. Spinning inside a cooperative system on a flag
       another process sets is how a guest stops pumping events.

   ---- overrun, which is reported and never hidden ---------------------

   The writer laps a slow reader. `write_cursor - cursor > ring_cap` means
   the bytes between them no longer exist; how many is arithmetic, and the
   drain reports it as `lostBytes` with `resync: true`.

   The resync lands on `write_cursor`, i.e. LIVE, and not on
   `write_cursor - ring_cap`, which would keep the oldest surviving bytes.
   Upstream made the same choice for the reason that still holds: without
   a record boundary to start from there is nothing that makes
   `write_cursor - ring_cap` the start of a record, and decoding from the
   middle of one produces plausible garbage. Losing a known quantity
   loudly beats decoding an unknown one quietly.

   `lostBytes` is bytes, not records - the records are gone, so their
   count is not knowable. Separately, `dropped` is the WRITER's own
   counter of records it could not fit, which is a different loss with a
   different cause, and the two are never summed. */

enum {
    kNowQDDrainOk = 0,       /* decoded to next_cursor; see `more`      */
    kNowQDDrainNoBlock = 1,  /* no block: extension absent or dark      */
    kNowQDDrainBadBlock = 2, /* magic / format / length / ring_cap bad  */
    kNowQDDrainBusy = 3,     /* seq odd on entry: a commit in flight    */
    kNowQDDrainTorn = 4,     /* the writer lapped us mid-read           */
    kNowQDDrainCorrupt = 5   /* a record `size` that cannot be one      */
};

/* One decoded record. The union is discriminated by `op`; a record whose
   op has no payload struct (or whose payload does not fit the bytes the
   header claims) still arrives, with `payload_ok = 0`, because "an op
   happened and we could not read its detail" is a fact and dropping it
   would understate the traffic. */
typedef struct {
    unsigned char op;
    unsigned char flags;
    int payload_ok;             /* 0 = header only, payload unreadable  */
    NowContentU32 port;
    NowContentU32 ticks;
    NowContentU32 a5;
    NowContentU32 psn_hi;
    NowContentU32 psn_lo;
    NowContentU32 display_epoch;
    NowContentU32 generation;
    NowContentU32 size;         /* the record's own size, incl. padding */
    union {
        NowContentTextPayload text;
        NowContentLinePayload line;
        NowContentRectPayload rect;
        NowContentBitsPayload bits;
        NowContentStatePayload state;
    } p;
    /* TEXT only: the inline bytes, NUL-terminated for the emitter's
       convenience. `p.text.len` is the byte count that is real;
       `p.text.full_len` is the run's TRUE length, which is larger when
       kNowContentFlagTruncText is set. */
    unsigned char text[kNowContentTextMax + 1];
} NowQDRecord;

/* Returns 1 to continue, 0 to stop the drain (the emitter's output is
   full). Stopping this way is `more`, never a silent end. */
typedef int (*NowQDSink)(void *ctx, const NowQDRecord *rec);

typedef struct {
    int outcome;                 /* kNowQDDrain*                        */
    NowContentU32 cursor;        /* where this drain actually STARTED,
                                    which differs from the requested one
                                    exactly when resync is set          */
    NowContentU32 next_cursor;   /* pass to the next drain              */
    NowContentU32 write_cursor;  /* the writer's cursor at entry        */
    NowContentU32 pending;       /* bytes from next_cursor to the writer*/
    NowContentU32 lost_bytes;    /* overrun: bytes that no longer exist */
    NowContentU32 dropped;       /* WRITER's counter, absolute          */
    NowContentU32 records;       /* handed to the sink                  */
    NowContentU32 wraps;         /* WRAP padding records stepped over   */
    int resync;                  /* cursor was moved because of overrun */
    int more;                    /* stopped on a budget, not on empty   */
} NowQDDrainResult;

/* Drain [cursor, write_cursor), bounded by both budgets. `max_bytes` 0
   means the whole ring; `max_records` 0 means no record bound. Reads
   only; the ONLY thing this touches in the block is nothing at all. */
void now_qdtrace_drain(const NowContentBlock *block,
                       NowContentU32 cursor,
                       NowContentU32 max_bytes,
                       NowContentU32 max_records,
                       NowQDSink sink, void *ctx,
                       NowQDDrainResult *out);

/* ---- status: the count-only question -------------------------------- */

typedef struct {
    int outcome;                 /* kNowQDDrain{Ok,NoBlock,BadBlock}    */
    NowContentU32 format;
    NowContentU32 length;
    NowContentU32 ring_cap;
    NowContentU32 write_cursor;
    NowContentU32 seq;
    NowContentU32 ticks;         /* TickCount at the writer's last commit */
    int committing;              /* seq was odd: a commit in flight     */

    /* What the extension says is armed (it writes these). */
    NowContentU32 active_a5;
    NowContentU32 active_mode;
    NowContentU32 hooked_ports;
    NowContentU32 active_window;
    NowContentU32 active_psn_hi;
    NowContentU32 active_psn_lo;
    NowContentU32 active_generation;
    NowContentU32 display_epoch;
    NowContentU32 redraw_requested_generation;
    NowContentU32 redraw_serviced_generation;
    NowContentU32 redraw_requests;
    NowContentU32 redraw_services;

    /* What the application asked for (we write these). Reported back so
       a request that the extension never honoured is VISIBLE as a
       mismatch rather than as an absence. */
    NowContentU32 arm_a5;
    NowContentU32 arm_expiry;
    NowContentU32 arm_mode;
    NowContentU32 arm_window;
    NowContentU32 arm_psn_hi;
    NowContentU32 arm_psn_lo;
    NowContentU32 arm_generation;
    int arm_committed;           /* arm_commit == 'NWca' exactly        */

    /* Occupancy relative to the caller's cursor. */
    NowContentU32 pending;       /* bytes waiting; capped at ring_cap   */
    NowContentU32 lost_bytes;    /* > 0 means the caller has fallen behind */
    int overrun;

    NowContentCounters counters;

    /* The GWorld probe (kNowContentModeProbe). has_probe says the block
       is long enough to carry the probe fields at all; a reader talking
       to an older resident sees 0 here and no probe key in the JSON. */
    int has_probe;
    NowContentU32 probe_pending_pixmap;
    NowContentU32 probe_pixmaps_seen;
    NowContentU32 probe_scans;
    NowContentU32 probe_hits;
    NowContentU32 probe_misses;
    NowContentU32 probe_offscreen_ports;
    NowContentU32 probe_stale_rows;
    NowContentU32 probe_last_match;
    NowContentU32 probe_already_ours;
    NowContentU32 probe_base_candidates;
    NowContentU32 probe_first_candidate;
    NowContentS16 probe_cand_l, probe_cand_t, probe_cand_r, probe_cand_b;
    NowContentU32 probe_sight_offers;
    NowContentU32 probe_sight_busy;
    NowContentU32 probe_sight_seen;
    NowContentU32 probe_last_sight;
    NowContentS16 probe_sight_l, probe_sight_t, probe_sight_r, probe_sight_b;
    NowContentU32 probe_sight_small;
} NowQDStatus;

void now_qdtrace_status(const NowContentBlock *block,
                        NowContentU32 cursor,
                        NowQDStatus *out);

/* Sum of the ten family counters - "is anything drawing at all" as one
   number. Separate from the honesty counters on purpose: adding
   `dropped` or `skipped_ports` into an op total would make loss look
   like drawing. */
NowContentU32 now_qdtrace_total_ops(const NowContentCounters *c);

/* ---- arming --------------------------------------------------------- */

/* A validated arm request. Building one cannot touch a block, so the
   validation is reachable from a host cc; committing one is four stores
   in a fixed order and is below. */
typedef struct {
    NowContentU32 a5;
    NowContentU32 expiry;
    NowContentU32 mode;
    NowContentU32 window;
    NowContentU32 psn_hi;
    NowContentU32 psn_lo;
    NowContentU32 generation;
} NowQDArmPlan;

enum {
    kNowQDArmOk = 0,
    kNowQDArmNoTarget = 1,   /* a5 absent or zero                       */
    kNowQDArmBadMode = 2,    /* not "count" or "record"                 */
    kNowQDArmBadTtl = 3      /* ttl outside the bounds below            */
};

/* Duration bounds, in ticks (60/s). A deadline exists so that an agent
   which dies mid-request does not leave hooks installed forever, so it
   must be short enough to matter; it also must not be so short that a
   plane which needs a human to go and draw something expires first.
   These two numbers are a JUDGEMENT and not a measurement, and they are
   the kind of number that should move once someone has watched a real
   drain. Default is deliberately at the short end. */
enum {
    kNowQDTtlMin = 60,        /* 1 second                               */
    kNowQDTtlDefault = 3600,  /* 60 seconds                             */
    kNowQDTtlMax = 36000      /* 10 minutes                             */
};

/* `mode_str` NULL or empty means count - the cheap mode, chosen as the
   default because the expensive one should be asked for by name. `a5` is
   REQUIRED and a zero one is refused here rather than being written and
   refused by the extension: a5 == 0 means "named no target", which the
   plane reads as "hook nothing", and a caller who believes zero means
   "everything" should be told no at the near end. */
int now_qdtrace_arm_plan(const char *mode_str,
                         NowContentU32 a5,
                         NowContentU32 window,
                         NowContentU32 psn_hi,
                         NowContentU32 psn_lo,
                         NowContentU32 generation,
                         long ttl_ticks,
                         NowContentU32 now_ticks,
                         NowQDArmPlan *out);

/* THE COMMIT ORDER IS THE CONTRACT (content_table.h): arm_a5, arm_expiry
   and mode FIRST, arm_commit LAST. A jGNE pass can land between any two
   of these stores, and that order is what stops a live commit word from
   ever pairing with the previous request's target. Disarm clears
   arm_commit FIRST for the same reason, read backwards.

   These are the only two functions in NOW that write the block. */
void now_qdtrace_arm_commit(NowContentBlock *block, const NowQDArmPlan *plan);
void now_qdtrace_disarm(NowContentBlock *block);

/* ---- the JSON half (Toolbox-free, tested natively) ------------------ */

/* Writes a whole command.result envelope into `out`. Both reserve tail
   room and stop cleanly rather than truncating; the drain emitter sets
   `more` on the result it was handed when the output, not the ring,
   is what ended it. */
void now_qdtrace_status_json(const NowQDStatus *st, long id,
                             char *out, long cap);

/* Drains straight into `out`. This is the emitter AND the sink: the
   output budget is the real limit on a drain (the ring budget only
   bounds how far the cursor may travel), so the two cannot be separated
   without the emitter guessing how much the decoder will produce. */
void now_qdtrace_drain_json(const NowContentBlock *block,
                            NowContentU32 cursor,
                            NowContentU32 max_bytes,
                            NowContentU32 max_records,
                            long id, char *out, long cap);

/* One-line refusal in the same envelope, for the states that have no
   payload to report: no block, bad block, a refused arm. */
void now_qdtrace_error_json(long id, const char *code, const char *message,
                            char *out, long cap);

/* ---- the Toolbox half ----------------------------------------------- */

/* The command, as the wire sees it. Registration is commands.c's, not
   ours - see the note in qdtrace_cmd.c. */
void now_qdtrace_run(const char *request_json, long id, char *out, long cap);

/* The block, found through the shared table, or NULL. Toolbox: it probes
   Gestalt through peek.c on every call. */
NowContentBlock *now_qdtrace_block(void);

#endif /* NOW_QDTRACE_H */
