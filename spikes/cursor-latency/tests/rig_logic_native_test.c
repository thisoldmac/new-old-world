/*
 * rig_logic_native_test.c - the rig's own accounting, on the host cc.
 *
 * These are the guards for the failures that make a measurement LIE
 * rather than fail: a ring that overflows quietly (so the tail reads
 * clean because the interesting part was discarded), coalescing that
 * loses its count (so a burst of ten reads as one), and out-of-order
 * application going unflagged (the one result that makes the whole
 * approach unusable).
 *
 * Each check names the mutation that must break it. Watch them fail -
 * `scripts/check --mutate N` reintroduces mutation N and expects red.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "cursor_rig.h"

static int failures;

static void ok(int cond, const char *what)
{
    if (!cond) {
        printf("FAIL %s\n", what);
        failures++;
    } else {
        printf("ok   %s\n", what);
    }
}

static RigTable *fresh(void)
{
    RigTable *t = (RigTable *)calloc(1, sizeof(RigTable));

    t->magic = kRigTableMagic;
    t->format = kRigTableFormat;
    t->length = (RigU32)sizeof(RigTable);
    t->ring_cap = kRigRingCap;
    rig_ring_reset(t);
    return t;
}

static RigCommand move(RigU32 seq, RigI16 h, RigI16 v)
{
    RigCommand c;

    memset(&c, 0, sizeof(c));
    c.magic = kRigWireMagic;
    c.version = kRigWireVersion;
    c.op = kRigOpMove;
    c.seq = seq;
    c.h = h;
    c.v = v;
    return c;
}

/* A burst that arrives while the writer is not scheduled must collapse
   to the newest, and must SAY how many it collapsed. Mutation: drop the
   `carried` roll-forward in rig_intake_stamp and this reads 1. */
static void test_coalesce_counts_the_burst(RigTable *t)
{
    RigCommand c;
    RigMailbox box;
    int i;

    rig_ring_reset(t);
    for (i = 1; i <= 10; ++i) {
        c = move((RigU32)i, (RigI16)(i * 10), 5);
        rig_intake_stamp(t, &c, 100);
    }
    ok(t->coalesced == 9, "nine of ten commands were superseded");
    ok(rig_mailbox_take(t, &box) == 1, "the mailbox held one command");
    ok(box.seq == 10 && box.h == 100, "and it is the NEWEST, not the oldest");
    ok(t->ring[9].coalesced == 9, "the survivor carries the burst's count");
    ok(rig_mailbox_take(t, &box) == 0, "an empty mailbox is safe to poll");
}

/* Mutation: delete the `ring_count >= ring_cap` guard and a wrapped run
   reports zero dropped, which is the shape of a clean result that is
   not one. */
static void test_ring_overflow_is_counted(RigTable *t)
{
    RigCommand c;
    RigMailbox box;
    RigU32 i;

    rig_ring_reset(t);
    for (i = 1; i <= (RigU32)kRigRingCap + 25; ++i) {
        c = move(i, 1, 1);
        rig_intake_stamp(t, &c, 200);
        rig_mailbox_take(t, &box);
        rig_apply_record(t, &box, 201);
    }
    ok(t->ring_dropped == 25, "25 samples past the ring's end were counted");
    ok(t->received == (RigU32)kRigRingCap + 25, "received is not capped");
}

/* The result that makes the approach unusable at any speed. Mutation:
   compare against the previous sample instead of the high-water mark,
   or drop the branch entirely. */
static void test_out_of_order_is_flagged(RigTable *t)
{
    RigCommand c;
    RigMailbox box;

    rig_ring_reset(t);
    c = move(50, 10, 10); rig_intake_stamp(t, &c, 300);
    rig_mailbox_take(t, &box); rig_apply_record(t, &box, 301);
    ok(t->out_of_order == 0, "a rising seq is not out of order");

    c = move(49, 20, 20); rig_intake_stamp(t, &c, 302);
    rig_mailbox_take(t, &box); rig_apply_record(t, &box, 303);
    ok(t->out_of_order == 1, "a seq below the high-water mark is flagged");
    ok((t->ring[1].flags & kRigSampleOutOfOrder) != 0,
       "and the sample itself carries the flag");
    ok(t->last_seq == 50, "the high-water mark does not go backwards");
}

/* A command whose ring slot was recycled while it sat in the mailbox
   must not stamp somebody else's sample. Mutation: drop the
   `s->seq == box->seq` guard and the apply lands on a stranger. */
static void test_apply_after_wrap_does_not_corrupt(RigTable *t)
{
    RigCommand c;
    RigMailbox box;
    RigU32 i;

    rig_ring_reset(t);
    c = move(1, 7, 7);
    rig_intake_stamp(t, &c, 400);
    rig_mailbox_take(t, &box);          /* held, not yet applied */

    for (i = 2; i <= (RigU32)kRigRingCap + 1; ++i) {
        c = move(i, 1, 1);
        rig_intake_stamp(t, &c, 401);
    }
    rig_apply_record(t, &box, 402);     /* slot 0 now belongs to seq 4097 */
    ok(t->ring[0].seq == (RigU32)kRigRingCap + 1, "slot 0 was recycled");
    ok(t->ring[0].apply_ticks == 0, "the stale apply did not stamp it");
    ok(t->applied == 1, "but the apply is still counted");
}

/* The picture is settled for the last APPLIED sample. Mutation: drop
   the applied check and an unapplied sample claims a drawn arrow. */
static void test_redraw_needs_an_applied_sample(RigTable *t)
{
    RigCommand c;
    RigMailbox box;

    rig_ring_reset(t);
    c = move(1, 5, 5);
    rig_intake_stamp(t, &c, 500);
    rig_redraw_record(t, 501);
    ok(t->redraws == 0, "an unapplied sample owes no picture");

    rig_mailbox_take(t, &box);
    rig_apply_record(t, &box, 502);
    rig_redraw_record(t, 503);
    ok(t->redraws == 1 && t->ring[0].redraw_ticks == 503,
       "the applied sample records when it was drawn");
    rig_redraw_record(t, 504);
    ok(t->redraws == 1, "a settled debt is not settled twice");
}

/* The case the first version of rig_redraw_record could not see, and it
   is the shape LOAD produces: a fresh command lands between the writer
   applying one and the event loop settling the picture, so the NEWEST
   ring entry is unapplied. Looking only at that entry recorded nothing
   and reported "the picture never updated under load" - false, and
   devastating if believed. Mutation: drop the lookback loop back to
   ring_head-1 only. */
static void test_redraw_settles_under_load_shape(RigTable *t)
{
    RigCommand c;
    RigMailbox box;

    rig_ring_reset(t);
    c = move(1, 5, 5);
    rig_intake_stamp(t, &c, 600);
    rig_mailbox_take(t, &box);
    rig_apply_record(t, &box, 601);         /* seq 1 applied */

    c = move(2, 6, 6);                      /* seq 2 arrives, NOT applied */
    rig_intake_stamp(t, &c, 602);

    rig_redraw_record(t, 603);
    ok(t->redraw_calls == 1, "the redraw itself is counted regardless");
    ok(t->redraws == 1,
       "and it is attributed to the newest APPLIED sample behind it");
    ok(t->ring[0].redraw_ticks == 603, "which is seq 1, not the unapplied one");
    ok(t->ring[1].redraw_ticks == 0, "the unapplied sample claims no picture");
}

/* The lookback must not walk past an already-settled sample into
   ancient history and re-stamp something. Mutation: remove the
   `redraw_ticks != 0` early return. */
static void test_redraw_stops_at_a_settled_sample(RigTable *t)
{
    RigCommand c;
    RigMailbox box;
    int i;

    rig_ring_reset(t);
    for (i = 1; i <= 3; ++i) {
        c = move((RigU32)i, (RigI16)i, (RigI16)i);
        rig_intake_stamp(t, &c, 700);
        rig_mailbox_take(t, &box);
        rig_apply_record(t, &box, 701);
    }
    rig_redraw_record(t, 702);              /* settles seq 3 */
    ok(t->ring[2].redraw_ticks == 702, "the newest applied sample settled");
    rig_redraw_record(t, 703);
    ok(t->redraws == 1, "a second pass finds it already settled and stops");
    ok(t->redraw_calls == 2, "but the second redraw is still counted");
    ok(t->ring[1].redraw_ticks == 0, "it did not reach back past it");
}

/* The layout the three compilers must agree on. This one is not a
   behaviour test: it is the reason the header is one file. */
static void test_layout(void)
{
    ok(sizeof(RigCommand) == kRigCommandSize, "RigCommand is 24 bytes");
    ok(sizeof(RigSample) == kRigSampleSize, "RigSample is 24 bytes");
    ok(sizeof(RigTable) > (unsigned long)kRigRingCap * kRigSampleSize,
       "RigTable carries its header and the whole ring");
}

int main(void)
{
    RigTable *t = fresh();

    test_layout();
    test_coalesce_counts_the_burst(t);
    test_ring_overflow_is_counted(t);
    test_out_of_order_is_flagged(t);
    test_apply_after_wrap_does_not_corrupt(t);
    test_redraw_needs_an_applied_sample(t);
    test_redraw_settles_under_load_shape(t);
    test_redraw_stops_at_a_settled_sample(t);

    free(t);
    printf("%s (%d failures)\n", failures ? "FAILED" : "passed", failures);
    return failures ? 1 : 0;
}
