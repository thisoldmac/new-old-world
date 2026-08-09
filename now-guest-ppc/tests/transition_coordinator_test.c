#include <stdio.h>
#include <string.h>

#include "transition_coordinator.h"

static int failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        failures++;
    }
}

static void form(NowEventBlock *block)
{
    memset(block, 0, sizeof *block);
    block->magic = (NowEventU32)kNowEventBlockMagic;
    block->format = kNowEventFormatV1;
    block->length = (NowEventU32)sizeof *block;
}

static void append(NowEventBlock *block, NowEventU32 kind)
{
    NowEventU32 cursor = block->write_cursor;
    NowEventRecord *record = &block->ring[
        cursor % (NowEventU32)kNowEventRingRecords];

    memset(record, 0, sizeof *record);
    record->seq = cursor + 1;
    record->kind = kind;
    block->write_cursor++;
}

int main(void)
{
    static NowTransitionCoordinator coordinator;
    static NowEventBlock source;
    NowMirrorInvalidation hint;
    NowEventRecord records[8];
    NowEventU32 next = 0;
    NowEventU32 resident_cursor;
    unsigned long lost = 0;
    unsigned long got;
    unsigned long i;

    form(&source);
    now_transition_coordinator_init(&coordinator);
    append(&source, kNowEventKindHeartbeat);
    append(&source, kNowEventKindWindowList);
    append(&source, kNowEventKindMenuList);

    got = now_transition_coordinator_ingest(&coordinator, &source, 32);
    check(got == 3, "one bounded ingest copies resident records");
    check(source.reader_cursor == 3,
          "the coordinator alone advances the resident cursor");
    check(now_transition_coordinator_take_invalidation(&coordinator, &hint),
          "changed domains produce one coalesced hint");
    check(hint.generation == 2 && hint.structure == 1 && hint.menus == 1,
          "heartbeat is excluded and domain generations are cumulative");
    check(hint.quality == kNowInvalidationSampled && hint.lost == 0,
          "a complete drain is sampled rather than a gap");
    check(!now_transition_coordinator_take_invalidation(&coordinator, &hint),
          "reading a hint twice cannot manufacture another generation");

    resident_cursor = source.reader_cursor;
    got = now_event_read(now_transition_coordinator_ledger(&coordinator), 0,
                         records, 2, &next, &lost);
    check(got == 2 && next == 2,
          "the console and command face read the application ledger");
    now_transition_coordinator_commit(&coordinator, next);
    check(source.reader_cursor == resident_cursor,
          "a face commit cannot race or move the resident cursor");

    append(&source, kNowEventKindFrontProcess);
    (void)now_transition_coordinator_ingest(&coordinator, &source, 32);
    check(now_transition_coordinator_take_invalidation(&coordinator, &hint)
              && hint.structure == 2 && hint.front == 1,
          "front changes invalidate both front and structural state");

    /* Fall more than one ring behind. The source's drop count and the
       reader-derived loss describe the same hole and must be charged once. */
    for (i = 0; i < (unsigned long)kNowEventRingRecords + 5; ++i) {
        append(&source, kNowEventKindHeartbeat);
    }
    source.dropped += 5;
    (void)now_transition_coordinator_ingest(&coordinator, &source, 32);
    check(now_transition_coordinator_take_invalidation(&coordinator, &hint),
          "a cursor hole produces an invalidation even with heartbeats only");
    check(hint.quality == kNowInvalidationGap && hint.lost == 5,
          "a resident drop is explicit and is not double-counted");
    check(hint.finder > 0 && hint.content > 0,
          "a gap conservatively requests every uncovered domain");

    if (failures != 0) {
        fprintf(stderr, "%d transition coordinator test(s) failed\n",
                failures);
        return 1;
    }
    puts("transition coordinator tests passed");
    return 0;
}
