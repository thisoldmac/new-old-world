#include "transition_coordinator.h"

#include "transitions_logic.h"

#include <string.h>

static void form_ledger(NowEventBlock *block)
{
    memset(block, 0, sizeof *block);
    block->format = kNowEventFormatV1;
    block->length = (NowEventU32)sizeof *block;
    block->magic = (NowEventU32)kNowEventBlockMagic;
}

void now_transition_coordinator_init(NowTransitionCoordinator *coordinator)
{
    if (coordinator == NULL) {
        return;
    }
    memset(coordinator, 0, sizeof *coordinator);
    form_ledger(&coordinator->ledger);
    coordinator->unannounced_quality = kNowInvalidationSampled;
}

static void copy_source_status(NowEventBlock *to, const NowEventBlock *from)
{
    to->arm_a5 = from->arm_a5;
    to->arm_expiry = from->arm_expiry;
    to->arm_commit = from->arm_commit;
    to->passes = from->passes;
    to->last_ticks = from->last_ticks;
}

static void advance_domain(NowTransitionCoordinator *coordinator,
                           NowEventU32 kind)
{
    switch (kind) {
    case kNowEventKindWindowList:
        coordinator->structure_generation++;
        break;
    case kNowEventKindFrontProcess:
        coordinator->structure_generation++;
        coordinator->front_generation++;
        break;
    case kNowEventKindMenuList:
        coordinator->menu_generation++;
        break;
    default:
        return;                 /* heartbeat is evidence, not invalidation */
    }
    coordinator->generation++;
}

static void append_record(NowTransitionCoordinator *coordinator,
                          const NowEventRecord *record)
{
    NowEventBlock *ledger = &coordinator->ledger;
    NowEventU32 outstanding = ledger->write_cursor - ledger->reader_cursor;
    unsigned long index;

    if (outstanding >= (NowEventU32)kNowEventRingRecords) {
        ledger->reader_cursor++;
        ledger->dropped++;
    }
    index = (unsigned long)(ledger->write_cursor
                            % (NowEventU32)kNowEventRingRecords);
    ledger->ring[index] = *record;
    ledger->write_cursor++;
    advance_domain(coordinator, record->kind);
}

static void note_gap(NowTransitionCoordinator *coordinator,
                     unsigned long lost)
{
    if (lost == 0) {
        return;
    }
    coordinator->generation++;
    coordinator->structure_generation++;
    coordinator->front_generation++;
    coordinator->menu_generation++;
    coordinator->finder_generation++;
    coordinator->content_generation++;
    coordinator->unannounced_lost += (NowEventU32)lost;
    coordinator->unannounced_quality = kNowInvalidationGap;
    coordinator->ledger.dropped += (NowEventU32)lost;
}

unsigned long now_transition_coordinator_ingest(
    NowTransitionCoordinator *coordinator, NowEventBlock *source,
    unsigned long max_records)
{
    NowEventRecord records[32];
    NowEventU32 next = 0;
    unsigned long lost = 0;
    unsigned long source_drop_delta = 0;
    unsigned long got;
    unsigned long i;

    if (coordinator == NULL || !now_event_block_usable(source)) {
        return 0;
    }
    if (!coordinator->bound) {
        coordinator->source_cursor = source->reader_cursor;
        coordinator->source_dropped = source->dropped;
        coordinator->bound = 1;
    }
    copy_source_status(&coordinator->ledger, source);
    if (max_records > 32) {
        max_records = 32;
    }
    got = now_event_read(source, coordinator->source_cursor, records,
                         max_records, &next, &lost);
    if (source->dropped != coordinator->source_dropped) {
        source_drop_delta = (unsigned long)(source->dropped
                                            - coordinator->source_dropped);
        coordinator->source_dropped = source->dropped;
    }
    /* `lost` and resident `dropped` describe overlapping evidence. Charge
       the larger once, not both, or one overwrite becomes two gaps. */
    note_gap(coordinator, lost > source_drop_delta ? lost : source_drop_delta);
    for (i = 0; i < got; ++i) {
        append_record(coordinator, &records[i]);
    }
    coordinator->source_cursor = next;
    source->reader_cursor = now_transitions_reader_advance(
        source->reader_cursor, next);
    return got;
}

int now_transition_coordinator_take_invalidation(
    NowTransitionCoordinator *coordinator, NowMirrorInvalidation *out)
{
    if (coordinator == NULL || out == NULL
        || coordinator->generation == coordinator->announced_generation) {
        return 0;
    }
    memset(out, 0, sizeof *out);
    out->generation = coordinator->generation;
    out->structure = coordinator->structure_generation;
    out->front = coordinator->front_generation;
    out->menus = coordinator->menu_generation;
    out->finder = coordinator->finder_generation;
    out->content = coordinator->content_generation;
    out->lost = coordinator->unannounced_lost;
    out->quality = coordinator->unannounced_quality;
    coordinator->announced_generation = coordinator->generation;
    coordinator->unannounced_lost = 0;
    coordinator->unannounced_quality = kNowInvalidationSampled;
    return 1;
}

const NowEventBlock *now_transition_coordinator_ledger(
    const NowTransitionCoordinator *coordinator)
{
    return coordinator != NULL && coordinator->bound
        ? &coordinator->ledger : NULL;
}

void now_transition_coordinator_commit(NowTransitionCoordinator *coordinator,
                                       NowEventU32 next)
{
    if (coordinator == NULL || !coordinator->bound) {
        return;
    }
    coordinator->ledger.reader_cursor = now_transitions_reader_advance(
        coordinator->ledger.reader_cursor, next);
}
