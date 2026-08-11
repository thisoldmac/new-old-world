/*
 * event_read.c - P5's ring reader, with no Toolbox in it.
 *
 * The precedent is qdtrace_read.c, and its reason applies here word for
 * word: the writer is resident code inside another process, running at
 * boot from a separately built binary, and the failure mode of a bad
 * decoder is not a crash but PLAUSIBLE OUTPUT. A decoder that cannot be
 * run against a fixture is a decoder nothing ever contradicts.
 *
 * This ring is simpler than the content one - fixed-width records, so
 * there is no `size` to distrust - which moves the whole risk to the
 * cursors. Those are the thing this file is careful about:
 *
 *   - the writer's cursor only ever advances, and it counts records
 *     EVER written, not a ring index. A reader that treated it as an
 *     index would read the same 256 records forever.
 *   - the distance between cursors can exceed the ring, and that is
 *     normal rather than exceptional: the reader is a wire round trip
 *     behind. When it does, the oldest records are gone and the reader
 *     is owed that fact, not a quiet renumbering.
 */

#include "event_read.h"

#include <string.h>

/* memcpy rather than a cast, for qdtrace_read.c's reason: a record's
   4-aligned fields can land on an address the host cc's sanitisers
   correctly object to, even where the 68K and PowerPC would survive. */
static NowEventU32 word_at(const unsigned char *base, unsigned long offset)
{
    NowEventU32 value;
    memcpy(&value, base + offset, sizeof value);
    return value;
}

int now_event_block_usable(const NowEventBlock *block)
{
    if (block == NULL) {
        return 0;
    }
    /* Magic is written last by the resident, so finding it means the
       header above it is complete. Format and length are checked
       because an older resident is a real case: it reports a shorter
       length and a reader that gated only on magic would walk a ring
       that is not there. */
    if (block->magic != (NowEventU32)kNowEventBlockMagic) {
        return 0;
    }
    if (block->format != kNowEventFormatV1) {
        return 0;
    }
    if (block->length < (NowEventU32)sizeof(NowEventBlock)) {
        return 0;
    }
    return 1;
}

/* How many records are readable, and how many were lost before them.
 *
 * `lost` is not the block's `dropped` counter. That one counts writes
 * the resident made while the reader was more than a ring behind; this
 * one is what THIS reader missed, derived from its own cursor. They
 * usually agree and they answer different questions, so both are
 * reported rather than one standing in for the other. */
unsigned long now_event_pending(const NowEventBlock *block,
                                NowEventU32 reader_cursor,
                                unsigned long *lost)
{
    NowEventU32 outstanding;

    if (lost != NULL) {
        *lost = 0;
    }
    if (!now_event_block_usable(block)) {
        return 0;
    }
    /* Unsigned subtraction, so a wrapped write cursor still gives the
       true distance. The cursor counts records ever written and will
       wrap after four billion of them; at one record a second that is
       136 years, and getting it right costs nothing. */
    outstanding = block->write_cursor - reader_cursor;
    if (outstanding > (NowEventU32)kNowEventRingRecords) {
        if (lost != NULL) {
            *lost = (unsigned long)(outstanding
                                    - (NowEventU32)kNowEventRingRecords);
        }
        return (unsigned long)kNowEventRingRecords;
    }
    return (unsigned long)outstanding;
}

/* Copy out up to `max` records, oldest first, and report where the
   reader now stands. Never blocks, never writes the block: advancing
   `reader_cursor` in shared memory is the caller's act, and it is
   separate so a caller that fails to deliver what it read does not lose
   it. */
unsigned long now_event_read(const NowEventBlock *block,
                             NowEventU32 reader_cursor,
                             NowEventRecord *out, unsigned long max,
                             NowEventU32 *next_cursor,
                             unsigned long *lost)
{
    unsigned long pending;
    unsigned long taken = 0;
    NowEventU32 cursor;
    const unsigned char *ring;

    pending = now_event_pending(block, reader_cursor, lost);
    if (next_cursor != NULL) {
        *next_cursor = reader_cursor;
    }
    if (pending == 0 || out == NULL || max == 0) {
        return 0;
    }
    /* Start at the oldest record still present. When the reader has
       fallen behind by more than the ring, that is NOT its own cursor -
       the records it names are overwritten - so it resumes at the
       oldest surviving one and the gap is reported through `lost`. */
    cursor = block->write_cursor - (NowEventU32)pending;
    ring = (const unsigned char *)block->ring;
    while (taken < max && taken < pending) {
        unsigned long index =
            (unsigned long)((cursor + (NowEventU32)taken)
                            % (NowEventU32)kNowEventRingRecords);
        unsigned long base = index * sizeof(NowEventRecord);
        out[taken].ticks = word_at(ring, base + 0);
        out[taken].seq = word_at(ring, base + 4);
        out[taken].kind = word_at(ring, base + 8);
        out[taken].a5 = word_at(ring, base + 12);
        out[taken].value = word_at(ring, base + 16);
        out[taken].previous = word_at(ring, base + 20);
        ++taken;
    }
    if (next_cursor != NULL) {
        *next_cursor = cursor + (NowEventU32)taken;
    }
    return taken;
}

/* The arm, in the order the contract requires: target and expiry first,
   commit last. Here rather than in the Toolbox half for qdtrace_read.c's
   reason - the order is a rule, and a rule belongs somewhere a test and
   a source gate can both see it. A jGNE pass can land between any two
   of these stores, and this order is what stops a live commit word from
   ever pairing with the previous request's target. */
void now_event_arm(NowEventBlock *block, NowEventU32 a5,
                   NowEventU32 expiry)
{
    if (block == NULL) {
        return;
    }
    block->arm_a5 = a5;
    block->arm_expiry = expiry;
    block->arm_commit = (a5 != 0 && expiry != 0) ? 1u : 0u;
}

void now_event_disarm(NowEventBlock *block)
{
    if (block == NULL) {
        return;
    }
    /* Commit FIRST, so no pass can find a live commit beside a cleared
       target and read it as a request naming nothing. */
    block->arm_commit = 0;
    block->arm_a5 = 0;
    block->arm_expiry = 0;
}
