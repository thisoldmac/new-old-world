/*
 * P5's ring reader, against a fixture the writer never touched.
 *
 * The decoder's failure mode is plausible output, not a crash, so it is
 * exercised here against rings built by hand — including the ones the
 * writer's own invariant says cannot happen, because the writer is a
 * separately built binary that loads at boot and the one certainty about
 * the pair is that they will at some point be different builds.
 */
#include <stdio.h>
#include <string.h>

#include "event_read.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

static void fill(NowEventBlock *block, NowEventU32 count)
{
    NowEventU32 i;
    for (i = 0; i < count; ++i) {
        unsigned long index = i % (NowEventU32)kNowEventRingRecords;
        block->ring[index].ticks = 1000 + i;
        block->ring[index].seq = i + 1;
        block->ring[index].kind = kNowEventKindWindowList;
        block->ring[index].a5 = 0x1000;
        block->ring[index].value = 0x2000 + i;
        block->ring[index].previous = 0x2000 + i - 1;
    }
    block->write_cursor = count;
}

int main(void)
{
    static NowEventBlock block;
    NowEventRecord out[512];
    NowEventU32 next;
    unsigned long lost, got;

    memset(&block, 0, sizeof block);

    /* ---- a block is not usable until it says it is ---- */
    check(now_event_block_usable(&block) == 0,
          "a zeroed block is not usable");
    block.magic = (NowEventU32)kNowEventBlockMagic;
    block.format = kNowEventFormatV1;
    block.length = (NowEventU32)sizeof block;
    check(now_event_block_usable(&block) == 1, "a formed block is usable");

    /* An older resident reports a shorter length. Gating only on magic
       would walk a ring that is not there. */
    block.length = 8;
    check(now_event_block_usable(&block) == 0,
          "a short block from an older resident is refused");
    block.length = (NowEventU32)sizeof block;

    block.format = 99;
    check(now_event_block_usable(&block) == 0,
          "an unknown format is refused rather than guessed");
    block.format = kNowEventFormatV1;

    /* ---- ordinary reading ---- */
    fill(&block, 5);
    check(now_event_pending(&block, 0, &lost) == 5 && lost == 0,
          "five written and none read is five pending");
    got = now_event_read(&block, 0, out, 512, &next, &lost);
    check(got == 5 && next == 5 && lost == 0, "all five come back");
    check(out[0].seq == 1 && out[4].seq == 5, "oldest first");
    check(out[0].value == 0x2000 && out[0].previous == 0x1FFF,
          "each record carries both values");

    /* A caller that reads and does not advance must not lose anything:
       reading is separate from advancing precisely for this. */
    got = now_event_read(&block, 0, out, 512, &next, &lost);
    check(got == 5, "re-reading from the same cursor sees the same five");

    got = now_event_read(&block, 5, out, 512, &next, &lost);
    check(got == 0 && next == 5, "a caught-up reader reads nothing");

    /* ---- bounded reads ---- */
    got = now_event_read(&block, 0, out, 2, &next, &lost);
    check(got == 2 && next == 2, "a bounded read advances only as far");

    /* ---- the wrap, which is the whole risk ---- */
    memset(&block, 0, sizeof block);
    block.magic = (NowEventU32)kNowEventBlockMagic;
    block.format = kNowEventFormatV1;
    block.length = (NowEventU32)sizeof block;
    fill(&block, (NowEventU32)kNowEventRingRecords + 10);

    /* The reader is 266 behind a 256-record ring: ten records are gone.
       It is owed that fact, not a quiet renumbering. */
    check(now_event_pending(&block, 0, &lost)
              == (unsigned long)kNowEventRingRecords,
          "a reader behind by more than the ring gets the ring");
    check(lost == 10, "and is told exactly how many it lost");
    got = now_event_read(&block, 0, out, 512, &next, &lost);
    check(got == (unsigned long)kNowEventRingRecords,
          "the full ring comes back");
    check(lost == 10, "the loss is reported alongside the records");
    /* Resumes at the OLDEST SURVIVING record, not at its own dead
       cursor: records 1..10 were overwritten, so the first survivor is
       seq 11. A decoder that started at the reader's cursor would return
       ten records of whatever now occupies those slots. */
    check(out[0].seq == 11, "reading resumes at the oldest survivor");
    check(next == block.write_cursor, "and ends caught up");

    /* ---- the arm's store order is the contract ---- */
    memset(&block, 0, sizeof block);
    now_event_arm(&block, 0x1000, 5000);
    check(block.arm_a5 == 0x1000 && block.arm_expiry == 5000
              && block.arm_commit == 1,
          "a complete request commits");
    now_event_arm(&block, 0, 5000);
    check(block.arm_commit == 0,
          "naming no target does not commit - it names nothing");
    now_event_arm(&block, 0x1000, 0);
    check(block.arm_commit == 0,
          "an already-expired request does not commit");

    now_event_arm(&block, 0x1000, 5000);
    now_event_disarm(&block);
    check(block.arm_commit == 0 && block.arm_a5 == 0,
          "disarm clears the request");

    /* ---- nothing crashes on nothing ---- */
    check(now_event_pending(NULL, 0, &lost) == 0, "no block, no records");
    check(now_event_read(NULL, 0, out, 512, &next, &lost) == 0,
          "no block, no read");
    now_event_arm(NULL, 1, 1);
    now_event_disarm(NULL);

    if (failures == 0) {
        printf("event_read_test ok\n");
    }
    return failures == 0 ? 0 : 1;
}
