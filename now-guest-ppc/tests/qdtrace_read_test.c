/*
 * qdtrace_read_test.c - the ring reader, on a host cc.
 *
 *   cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST -I contract \
 *      -I ext/src -I now-guest-ppc/src/content \
 *      now-guest-ppc/tests/qdtrace_read_test.c \
 *      now-guest-ppc/src/content/qdtrace_read.c \
 *      ext/src/now_content_logic.c -o /tmp/t && /tmp/t
 *
 * (scripts/test-native runs exactly that.)
 *
 * THE FIXTURES ARE WRITTEN BY THE REAL WRITER. now_content_ring_put is
 * linked in and used to build every well-formed ring here, so the two
 * halves of the contract are tested against each other rather than
 * against two readings of the same header. Where a ring must be
 * MALFORMED - a size that cannot be a record's, a record straddling the
 * ring's end - the bytes are poked in by hand, because the writer cannot
 * produce them and the reader must survive them anyway. That asymmetry is
 * deliberate: the writer's invariants are the writer's, and the writer is
 * a separately loaded binary that will one day be a different build.
 *
 * WHAT THIS CANNOT COVER: a real writer running concurrently. Classic Mac
 * OS is cooperative and the host is not, so the `torn` case is produced
 * by having the SINK write into the ring mid-walk - which is the exact
 * interleaving the seqlock re-sample exists to catch, executed
 * deterministically instead of hoped for.
 */

#include "qdtrace.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int cond, const char *what)
{
    if (!cond) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void check_eq(long got, long want, const char *what)
{
    if (got != want) {
        printf("FAIL %s: got %ld want %ld\n", what, got, want);
        failures++;
    }
}

/* ---- fixtures -------------------------------------------------------- */

static NowContentBlock g_block;

static void init_block(NowContentU32 cap)
{
    memset(&g_block, 0, sizeof g_block);
    g_block.format = (NowContentU16)kNowContentFormatV1;
    g_block.ring_cap = cap;
    g_block.length = (NowContentU32)(offsetof(NowContentBlock, ring) + cap);
    g_block.magic = (NowContentU32)kNowContentBlockMagic;
}

/* A header-only record: 12 bytes, the smallest thing the ring holds. */
static void put_bare(NowContentU32 port)
{
    (void)now_content_ring_put(&g_block, kNowContentOpRgn, 0, port, NULL, 0);
}

/* ---- a sink that just collects --------------------------------------- */

typedef struct {
    NowQDRecord recs[64];
    int n;
    int stop_after;      /* 0 = never stop                              */
} Collector;

static int collect(void *ctx, const NowQDRecord *rec)
{
    Collector *c = (Collector *)ctx;

    if (c->stop_after != 0 && c->n >= c->stop_after) {
        return 0;
    }
    if (c->n < (int)(sizeof c->recs / sizeof c->recs[0])) {
        c->recs[c->n] = *rec;
    }
    c->n++;
    return 1;
}

/* ---- block acceptance ------------------------------------------------ */

static void test_block_acceptance(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    now_qdtrace_drain(NULL, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainNoBlock, "NULL block is no-block");

    init_block(256);
    g_block.magic = 0;
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainBadBlock, "bad magic refuses");

    init_block(256);
    g_block.format = 99;
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainBadBlock, "unknown format refuses");

    /* An odd capacity would put a 2-aligned record at an odd offset after
       one wrap, and a capacity larger than the array we compiled against
       would walk off its end. Both are refusals, not clamps. */
    init_block(255);
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainBadBlock, "odd ring_cap refuses");

    init_block(256);
    g_block.ring_cap = (NowContentU32)kNowContentRingCap + 2u;
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainBadBlock, "oversized ring_cap refuses");

    init_block(256);
    g_block.length = 40;
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainBadBlock, "short length refuses");
}

/* ---- an empty ring is empty, and says so ----------------------------- */

static void test_empty(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    init_block(256);
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "empty ring drains ok");
    check_eq(r.records, 0, "empty ring yields no records");
    check_eq((long)r.next_cursor, 0, "empty ring does not move the cursor");
    check_eq(r.more, 0, "empty is not `more`");
    check_eq(r.resync, 0, "empty is not a resync");
}

/* ---- every family decodes, with its own fields ----------------------- */

static void test_families(void)
{
    NowQDDrainResult r;
    Collector c;
    NowContentTextPayload tp;
    NowContentLinePayload lp;
    NowContentRectPayload rp;
    NowContentBitsPayload bp;
    NowContentStatePayload sp;
    const char *word = "Hi";

    memset(&c, 0, sizeof c);
    init_block(4096);
    g_block.ticks = 1234;

    memset(&tp, 0, sizeof tp);
    tp.pen_h = 10;
    tp.pen_v = -20;
    tp.tx_font = 3;
    tp.tx_size = 9;
    tp.tx_face = 1;
    tp.len = 2;
    tp.full_len = 2;
    {
        unsigned char buf[sizeof tp + 2];

        memcpy(buf, &tp, sizeof tp);
        memcpy(buf + sizeof tp, word, 2);
        check_eq(now_content_ring_put(&g_block, kNowContentOpText, 0,
                                      0xAABBCCDDu, buf,
                                      (NowContentU16)(sizeof tp + 2)),
                 1, "text record commits");
    }

    memset(&lp, 0, sizeof lp);
    lp.from_h = 1; lp.from_v = 2; lp.to_h = 3; lp.to_v = 4;
    lp.pn_h = 1; lp.pn_v = 1;
    (void)now_content_ring_put(&g_block, kNowContentOpLine, 0, 0x11u,
                               &lp, (NowContentU16)sizeof lp);

    memset(&rp, 0, sizeof rp);
    rp.verb = 1; rp.l = -5; rp.t = -6; rp.r = 7; rp.b = 8;
    rp.ext1 = 2; rp.ext2 = 3;
    (void)now_content_ring_put(&g_block, kNowContentOpRRect, 0, 0x22u,
                               &rp, (NowContentU16)sizeof rp);

    memset(&bp, 0, sizeof bp);
    bp.sl = 4; bp.st = 4; bp.sr = 418; bp.sb = 147;
    bp.dl = 4; bp.dt = -29; bp.dr = 418; bp.db = 114;
    bp.mode = 8; bp.src_row_bytes = 64;
    (void)now_content_ring_put(&g_block, kNowContentOpBits, 0, 0x33u,
                               &bp, (NowContentU16)sizeof bp);

    memset(&sp, 0, sizeof sp);
    sp.kind = kNowContentStateFg;
    sp.a = (NowContentS16)0xFFFF;   /* full-scale red: unsigned on the wire */
    sp.b = 0; sp.c = 0;
    (void)now_content_ring_put(&g_block, kNowContentOpState, 0, 0x44u,
                               &sp, (NowContentU16)sizeof sp);

    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "families drain ok");
    check_eq(c.n, 5, "five records decoded");
    check_eq((long)r.records, 5, "five records reported");
    check_eq((long)r.next_cursor, (long)g_block.write_cursor,
             "a full drain lands on the write cursor");

    check_eq(c.recs[0].op, kNowContentOpText, "record 0 is text");
    check((unsigned long)c.recs[0].port == 0xAABBCCDDu, "text keeps its port");
    check_eq((long)c.recs[0].ticks, 1234, "text keeps its ticks");
    check_eq(c.recs[0].payload_ok, 1, "text payload readable");
    check_eq(c.recs[0].p.text.pen_h, 10, "text pen h");
    check_eq(c.recs[0].p.text.pen_v, -20, "text pen v");
    check(strcmp((const char *)c.recs[0].text, "Hi") == 0,
          "text bytes survive");

    check_eq(c.recs[1].p.line.to_v, 4, "line to v");
    check_eq(c.recs[2].p.rect.l, -5, "rrect keeps a negative left");
    check_eq(c.recs[2].p.rect.ext1, 2, "rrect keeps its oval width");
    check_eq(c.recs[3].p.bits.dt, -29, "bits keeps a negative dst top");
    check_eq(c.recs[3].p.bits.src_row_bytes, 64, "bits rowBytes");
    check_eq(c.recs[4].p.state.kind, kNowContentStateFg, "state kind");
}

/* A record whose payload is shorter than its family needs still ARRIVES,
   with payload_ok clear. An op that happened and could not be read in
   full is a fact; dropping it would understate the traffic, which is the
   direction that reads as a quiet machine. */
static void test_short_payload_still_reports_the_op(void)
{
    NowQDDrainResult r;
    Collector c;
    unsigned char stub[4] = { 0, 0, 0, 0 };

    memset(&c, 0, sizeof c);
    init_block(256);
    (void)now_content_ring_put(&g_block, kNowContentOpBits, 0, 0x99u,
                               stub, (NowContentU16)sizeof stub);
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(c.n, 1, "a truncated record is still delivered");
    check_eq(c.recs[0].payload_ok, 0, "and is marked detail-less");
    check_eq(c.recs[0].op, kNowContentOpBits, "with its family intact");
}

/* An op number this build does not know is a NEWER WRITER, not garbage.
   Reported as a header. */
static void test_unknown_op_is_reported(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    init_block(256);
    (void)now_content_ring_put(&g_block, 200, 0, 0x1u, NULL, 0);
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "an unknown op is not corruption");
    check_eq(c.n, 1, "and is delivered");
    check_eq(c.recs[0].payload_ok, 0, "without a payload claim");
}

/* ---- the wrap, and the tail the port fixed --------------------------- */

/* cap 256, 12-byte records: the 21st put would leave a 4-byte tail, too
   short to hold a header. The writer absorbs it, so that record's `size`
   is 16 and the ring ends exactly on the boundary. The reader steps by
   `size` and never sees the absorbed bytes - which is the whole point of
   the fix, and is only true if the reader really does step by `size`. */
static void test_tail_absorption(void)
{
    NowQDDrainResult r;
    Collector c;
    int i;

    memset(&c, 0, sizeof c);
    init_block(256);
    for (i = 0; i < 21; ++i) {
        put_bare((NowContentU32)(100 + i));
    }
    check_eq((long)g_block.write_cursor, 256,
             "21 bare records fill the ring exactly");

    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "the absorbed tail drains ok");
    check_eq(c.n, 21, "all 21 records come back");
    check_eq((long)c.recs[20].size, 16, "the last record absorbed the tail");
    check_eq((long)c.recs[20].port, 120, "and is still the record it was");
    check_eq((long)r.next_cursor, 256, "landing on the boundary");
}

/* Past the boundary, the writer emits a WRAP pad when a record will not
   fit the tail. The reader steps over it and counts it - a WRAP is not a
   record and must not be delivered as one.

   Note what the fixture had to do to exist: a wrap only happens on a full
   ring, so a reader still holding cursor 0 has by definition been lapped
   and gets a resync instead. A wrap is therefore only observable by a
   reader that is KEEPING UP, which is the reader this case is about. */
static void test_wrap_padding_is_stepped_over(void)
{
    NowQDDrainResult r;
    Collector c;
    int i;

    memset(&c, 0, sizeof c);
    init_block(512);
    /* 20-byte records: 25 fill 500 bytes, the 26th does not fit the
       12-byte tail, so the writer pads it and starts again at 0. */
    for (i = 0; i < 26; ++i) {
        unsigned char body[8];

        memset(body, (int)i, sizeof body);
        (void)now_content_ring_put(&g_block, kNowContentOpRgn, 0,
                                   (NowContentU32)i, body,
                                   (NowContentU16)sizeof body);
    }
    check_eq((long)g_block.write_cursor, 532, "25 records, a pad, and one more");

    now_qdtrace_drain(&g_block, 20u, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "a padded ring drains ok");
    check_eq(c.n, 25, "25 records, and the pad is not one of them");
    check_eq((long)r.wraps, 1, "the pad is counted as a wrap");
    check_eq((long)c.recs[24].port, 25, "including the one after the wrap");
    check_eq((long)r.next_cursor, (long)g_block.write_cursor,
             "the cursor lands on the writer's");
}

/* ---- malformed rings the writer cannot produce ----------------------- */

/* THE DEFECT THE PORT FIXED, from the reader's side. Upstream's wrap path
   could leave a tail too short to hold a header, and a record-stepping
   reader reads such a tail AS a header. Here the bytes are poked in by
   hand: a `size` below the header minimum. It must be refused, not
   stepped by. */
static void test_undersized_size_is_corrupt(void)
{
    NowQDDrainResult r;
    Collector c;
    NowContentRecHeader h;

    memset(&c, 0, sizeof c);
    init_block(256);
    memset(&h, 0, sizeof h);
    h.size = 4;                        /* a tail, read as a header */
    h.op = kNowContentOpRgn;
    memcpy(&g_block.ring[0], &h, sizeof h);
    g_block.write_cursor = 64;

    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainCorrupt, "an impossible size is corrupt");
    check_eq(c.n, 0, "and nothing is delivered from it");
}

/* Records are never wrapped mid-record, so one that runs off the ring's
   end is not a record. Stepping by it would land the next read at an
   offset the writer never wrote. */
static void test_straddling_record_is_corrupt(void)
{
    NowQDDrainResult r;
    Collector c;
    NowContentRecHeader h;

    memset(&c, 0, sizeof c);
    init_block(256);
    /* pos 240 leaves room for a header (16 bytes), so the reader gets far
       enough to READ this record - and its size runs 4 bytes past the
       ring's end. A tail shorter than a header is caught earlier and by a
       different check; this is the case only the size arithmetic sees. */
    memset(&h, 0, sizeof h);
    h.size = 20;
    h.op = kNowContentOpRgn;
    memcpy(&g_block.ring[240], &h, sizeof h);   /* 240 + 20 > 256 */
    g_block.write_cursor = 260;

    now_qdtrace_drain(&g_block, 240, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainCorrupt, "a straddling record is corrupt");
    check_eq(c.n, 0, "and is not delivered on the way to saying so");

    /* And the tail-too-short-for-a-header case, which the writer's own
       invariant is supposed to make impossible. */
    memset(&c, 0, sizeof c);
    init_block(256);
    memset(&h, 0, sizeof h);
    h.size = 12;
    h.op = kNowContentOpRgn;
    memcpy(&g_block.ring[250], &h, sizeof h);
    g_block.write_cursor = 262;
    now_qdtrace_drain(&g_block, 250, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainCorrupt, "a tail too short is corrupt");
}

/* An odd size would put the following record at an odd offset, and every
   record struct in the contract is 2-aligned by construction. */
static void test_odd_size_is_corrupt(void)
{
    NowQDDrainResult r;
    Collector c;
    NowContentRecHeader h;

    memset(&c, 0, sizeof c);
    init_block(256);
    memset(&h, 0, sizeof h);
    h.size = 13;
    h.op = kNowContentOpRgn;
    memcpy(&g_block.ring[0], &h, sizeof h);
    g_block.write_cursor = 64;

    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainCorrupt, "an odd size is corrupt");
    /* Delivering it and THEN discovering the corruption is not the same
       thing: an odd size puts every following record at an offset the
       writer never wrote, so the first one is already untrustworthy. */
    check_eq(c.n, 0, "and nothing from it is delivered first");
}

/* ---- overrun: a fact, reported ---------------------------------------- */

static void test_overrun_reports_the_loss(void)
{
    NowQDDrainResult r;
    Collector c;
    int i;

    memset(&c, 0, sizeof c);
    init_block(256);
    /* 30 bare records = 360 bytes past a 256-byte ring; a reader holding
       cursor 0 has lost 360 - 256 = 104 bytes. The exact number matters:
       "you fell behind" without a quantity is not a report. */
    for (i = 0; i < 30; ++i) {
        put_bare((NowContentU32)i);
    }
    check(g_block.write_cursor - 0 > 256, "the fixture really did lap");

    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "an overrun is not an error");
    check_eq(r.resync, 1, "an overrun resyncs");
    check_eq((long)r.lost_bytes, (long)(g_block.write_cursor - 256u),
             "and says how many bytes are gone");
    check_eq((long)r.cursor, (long)g_block.write_cursor,
             "resync lands LIVE, not on the oldest survivor");
    check_eq((long)r.next_cursor, (long)g_block.write_cursor,
             "so the drain that resyncs delivers nothing");
    check_eq(c.n, 0, "and no records are decoded from an unknown boundary");
}

/* A cursor AHEAD of the writer is not a two-billion-byte loss. It is a
   cursor that did not come from this ring - a stale session, another
   block, a fabricated number - and reporting it as a measured loss would
   be a fabricated measurement. */
static void test_cursor_ahead_of_writer(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    init_block(256);
    put_bare(1);
    now_qdtrace_drain(&g_block, 100000u, 0, 0, collect, &c, &r);
    check_eq(r.resync, 1, "a foreign cursor resyncs");
    check_eq((long)r.lost_bytes, 0, "with no invented loss");
    check_eq((long)r.cursor, (long)g_block.write_cursor, "onto the writer");
}

/* The writer's own drop counter is a DIFFERENT loss with a different
   cause, and is reported alongside rather than summed into lost_bytes. */
static void test_dropped_is_carried_separately(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    init_block(256);
    g_block.counters.dropped = 7;
    put_bare(1);
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq((long)r.dropped, 7, "the writer's drops are reported");
    check_eq((long)r.lost_bytes, 0, "and are not overrun bytes");
}

/* ---- the seqlock ------------------------------------------------------ */

static void test_busy_when_a_commit_is_in_flight(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    init_block(256);
    put_bare(1);
    g_block.seq |= 1u;                  /* a commit in flight right now */

    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainBusy, "an odd seq is busy");
    check_eq(c.n, 0, "and nothing is read under it");
    check_eq((long)r.write_cursor, (long)g_block.write_cursor,
             "busy still reports where the writer is");
}

/* The writer lapping DURING the walk. The sink writes into the ring on
   its first call, which is the interleaving the seqlock re-sample exists
   to catch - here made deterministic rather than hoped for. */
static int lapping_sink(void *ctx, const NowQDRecord *rec)
{
    Collector *c = (Collector *)ctx;
    int i;

    (void)rec;
    if (c->n == 0) {
        for (i = 0; i < 40; ++i) {
            put_bare((NowContentU32)(500 + i));
        }
    }
    c->n++;
    return 1;
}

static void test_torn_read_is_discarded(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    init_block(256);
    put_bare(1);
    put_bare(2);
    put_bare(3);

    now_qdtrace_drain(&g_block, 0, 0, 0, lapping_sink, &c, &r);
    check_eq(r.outcome, kNowQDDrainTorn, "a lapped read is torn");
    check_eq((long)r.records, 0, "a torn read delivers nothing");
    check_eq(r.resync, 1, "and is a resync");
    check_eq((long)r.next_cursor, (long)g_block.write_cursor,
             "resuming live");
}

/* A writer that commits during the walk WITHOUT lapping has not
   invalidated anything: the bytes we read are behind it and still
   there. Bumping seq alone must not cost the caller its answer. */
static int nudging_sink(void *ctx, const NowQDRecord *rec)
{
    Collector *c = (Collector *)ctx;

    (void)rec;
    if (c->n == 0) {
        put_bare(900);
    }
    if (c->n < (int)(sizeof c->recs / sizeof c->recs[0])) {
        c->recs[c->n] = *rec;
    }
    c->n++;
    return 1;
}

static void test_a_commit_that_did_not_lap_is_kept(void)
{
    NowQDDrainResult r;
    Collector c;

    memset(&c, 0, sizeof c);
    init_block(4096);
    put_bare(1);
    put_bare(2);

    now_qdtrace_drain(&g_block, 0, 24u, 0, nudging_sink, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "a non-lapping commit keeps the read");
    check_eq((long)r.records, 2, "and its records");
}

/* ---- budgets: short for a reason ------------------------------------- */

static void test_byte_budget_sets_more(void)
{
    NowQDDrainResult r;
    Collector c;
    int i;

    memset(&c, 0, sizeof c);
    init_block(4096);
    for (i = 0; i < 10; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain(&g_block, 0, 36u, 0, collect, &c, &r);
    check_eq(r.outcome, kNowQDDrainOk, "a bounded drain is ok");
    check_eq(c.n, 3, "three 12-byte records fit 36 bytes");
    check_eq(r.more, 1, "and the rest is `more`, not silence");
    check_eq((long)r.next_cursor, 36, "the cursor stops on a boundary");
    check_eq((long)r.pending, (long)(g_block.write_cursor - 36u),
             "with the remainder reported");
}

static void test_byte_budget_that_splits_a_record(void)
{
    NowQDDrainResult r;
    Collector c;
    int i;

    memset(&c, 0, sizeof c);
    init_block(4096);
    for (i = 0; i < 10; ++i) {
        put_bare((NowContentU32)i);
    }
    /* 30 bytes is two records and half of a third. The half is not
       delivered and the cursor does not advance into it. */
    now_qdtrace_drain(&g_block, 0, 30u, 0, collect, &c, &r);
    check_eq(c.n, 2, "a record is never split across drains");
    check_eq((long)r.next_cursor, 24, "the cursor stops before it");
    check_eq(r.more, 1, "and says there is more");
}

static void test_record_budget_sets_more(void)
{
    NowQDDrainResult r;
    Collector c;
    int i;

    memset(&c, 0, sizeof c);
    init_block(4096);
    for (i = 0; i < 10; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain(&g_block, 0, 0, 4u, collect, &c, &r);
    check_eq(c.n, 4, "the record budget holds");
    check_eq(r.more, 1, "and the remainder is `more`");

    memset(&c, 0, sizeof c);
    now_qdtrace_drain(&g_block, 0, 0, 10u, collect, &c, &r);
    check_eq(c.n, 10, "a budget equal to the ring's contents");
    check_eq(r.more, 0, "is not `more`");
}

/* The sink refusing - the consumer's output filled. The record it refused
   must be re-readable, so the cursor must NOT advance past it. */
static void test_sink_refusal_does_not_consume(void)
{
    NowQDDrainResult r;
    Collector c;
    int i;

    memset(&c, 0, sizeof c);
    c.stop_after = 2;
    init_block(4096);
    for (i = 0; i < 10; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_drain(&g_block, 0, 0, 0, collect, &c, &r);
    check_eq((long)r.records, 2, "two records were taken");
    check_eq(r.more, 1, "the refusal is `more`");
    check_eq((long)r.next_cursor, 24, "and the refused record is not consumed");

    memset(&c, 0, sizeof c);
    now_qdtrace_drain(&g_block, r.next_cursor, 0, 0, collect, &c, &r);
    check_eq(c.n, 8, "so the next drain re-reads it");
    check_eq((long)c.recs[0].port, 2, "starting exactly where it stopped");
}

/* ---- status: the count-only question --------------------------------- */

static void test_status(void)
{
    NowQDStatus st;

    now_qdtrace_status(NULL, 0, &st);
    check_eq(st.outcome, kNowQDDrainNoBlock, "no block, no status");

    init_block(256);
    g_block.counters.text = 41;
    g_block.counters.bits = 0;
    g_block.counters.dropped = 3;
    g_block.counters.skipped_ports = 2;
    g_block.active_a5 = 0x1000u;
    g_block.active_mode = kNowContentModeRecord;
    g_block.arm_a5 = 0x1000u;
    g_block.arm_commit = (NowContentU32)kNowContentArmCommit;
    put_bare(1);

    now_qdtrace_status(&g_block, 0, &st);
    check_eq(st.outcome, kNowQDDrainOk, "status reads");
    check_eq((long)st.pending, 12, "12 bytes waiting");
    check_eq(st.overrun, 0, "no overrun");
    check_eq(st.arm_committed, 1, "the commit word is exact");
    check_eq((long)st.counters.text, 41, "counters are carried whole");
    check_eq(st.committing, 0, "not mid-commit");

    /* The commit word is deliberately not 1: a scribbled or stale block
       must not read as permission. */
    g_block.arm_commit = 1;
    now_qdtrace_status(&g_block, 0, &st);
    check_eq(st.arm_committed, 0, "a bare 1 is not the commit word");
}

static void test_status_reports_overrun_without_a_drain(void)
{
    NowQDStatus st;
    int i;

    init_block(256);
    for (i = 0; i < 30; ++i) {
        put_bare((NowContentU32)i);
    }
    now_qdtrace_status(&g_block, 0, &st);
    check_eq(st.overrun, 1, "status sees the overrun");
    check_eq((long)st.lost_bytes, (long)(g_block.write_cursor - 256u),
             "and quantifies it, without moving a record");
    check_eq((long)st.pending, 256, "pending is capped at the ring");
}

static void test_total_ops_excludes_losses(void)
{
    NowContentCounters c;

    memset(&c, 0, sizeof c);
    c.text = 41;
    c.bits = 2;
    c.other = 1;
    c.dropped = 100;
    c.skipped_ports = 100;
    check_eq((long)now_qdtrace_total_ops(&c), 44,
             "a loss is not drawing and is not summed into it");
}

/* ---- arming ----------------------------------------------------------- */

static void test_arm_plan(void)
{
    NowQDArmPlan p;

    check_eq(now_qdtrace_arm_plan("record", 0, 600, 1000, &p),
             kNowQDArmNoTarget, "no target is refused at the near end");
    check_eq(now_qdtrace_arm_plan("both", 0x1000u, 600, 1000, &p),
             kNowQDArmBadMode, "an unknown mode is refused");
    check_eq(now_qdtrace_arm_plan("count", 0x1000u, 1, 1000, &p),
             kNowQDArmBadTtl, "a sub-second deadline is refused");
    check_eq(now_qdtrace_arm_plan("count", 0x1000u, 999999, 1000, &p),
             kNowQDArmBadTtl, "an unbounded deadline is refused");

    check_eq(now_qdtrace_arm_plan(NULL, 0x1000u, 0, 1000, &p), kNowQDArmOk,
             "defaults arm");
    check_eq((long)p.mode, kNowContentModeCount,
             "and the default mode is the cheap one");
    check_eq((long)p.expiry, 1000 + kNowQDTtlDefault, "with a bounded deadline");

    check_eq(now_qdtrace_arm_plan("record", 0x1000u, 600, 1000, &p),
             kNowQDArmOk, "record mode arms");
    check_eq((long)p.mode, kNowContentModeRecord, "as record");
    check_eq((long)p.a5, 0x1000, "at the named target");

    /* TickCount wraps. An expiry that lands on exactly 0 means "expired
       on sight" in the contract, which would silently turn a request into
       a no-op once every 2^32 ticks. */
    check_eq(now_qdtrace_arm_plan("count", 0x1000u, 60,
                                  (NowContentU32)(0u - 60u), &p),
             kNowQDArmOk, "an expiry across the tick wrap arms");
    check(p.expiry != 0, "and never lands on the expired-on-sight value");
}

/* The commit word is written LAST and cleared FIRST. An end-state test
   cannot see an ordering - qdtrace_arm_order_source_test.py reads the
   source for that - so what is checked here is that the end states are
   the ones the extension's verdict function actually accepts and
   refuses. Linking now_content_arm_verdict in is the point: the reader's
   write and the writer's read are tested against each other. */
static void test_arm_commit_end_state(void)
{
    NowQDArmPlan p;
    NowContentRequest req;

    init_block(256);
    check_eq(now_qdtrace_arm_plan("record", 0x1000u, 600, 1000, &p),
             kNowQDArmOk, "plan builds");
    now_qdtrace_arm_commit(&g_block, &p);

    req.plane_bits = (NowContentU32)kNowPeekTableCapContent;
    req.arm_commit = g_block.arm_commit;
    req.arm_a5 = g_block.arm_a5;
    req.arm_expiry = g_block.arm_expiry;
    req.mode = g_block.mode;
    check_eq(now_content_arm_verdict(&req, 0x1000u, 1100u),
             kNowContentVerdictArmed,
             "what we wrote is what the extension arms on");
    check_eq(now_content_arm_verdict(&req, 0x2000u, 1100u),
             kNowContentVerdictOtherContext,
             "and it is scoped to the ONE named context");

    now_qdtrace_disarm(&g_block);
    req.arm_commit = g_block.arm_commit;
    req.arm_a5 = g_block.arm_a5;
    req.arm_expiry = g_block.arm_expiry;
    req.mode = g_block.mode;
    check_eq(now_content_arm_verdict(&req, 0x1000u, 1100u),
             kNowContentVerdictIdle, "and disarm really disarms");
    check_eq((long)g_block.arm_a5, 0, "leaving no stale target behind");
}

int main(void)
{
    test_block_acceptance();
    test_empty();
    test_families();
    test_short_payload_still_reports_the_op();
    test_unknown_op_is_reported();
    test_tail_absorption();
    test_wrap_padding_is_stepped_over();
    test_undersized_size_is_corrupt();
    test_straddling_record_is_corrupt();
    test_odd_size_is_corrupt();
    test_overrun_reports_the_loss();
    test_cursor_ahead_of_writer();
    test_dropped_is_carried_separately();
    test_busy_when_a_commit_is_in_flight();
    test_torn_read_is_discarded();
    test_a_commit_that_did_not_lap_is_kept();
    test_byte_budget_sets_more();
    test_byte_budget_that_splits_a_record();
    test_record_budget_sets_more();
    test_sink_refusal_does_not_consume();
    test_status();
    test_status_reports_overrun_without_a_drain();
    test_total_ops_excludes_losses();
    test_arm_plan();
    test_arm_commit_end_state();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
