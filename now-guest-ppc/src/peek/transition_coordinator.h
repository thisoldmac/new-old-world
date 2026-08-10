/*
 * transition_coordinator.h - application-owned P5 drain and generations.
 *
 * The resident ring has one reader cursor. The console, command wire and
 * automatic Mirror invalidation used to be three plausible owners of it;
 * whichever arrived first could make the others observe false absence. This
 * coordinator is the sole shared-memory reader. It copies bounded records to
 * an application-owned ledger, from which the human command faces read, and
 * reduces the same records to monotonic invalidation generations.
 *
 * No Toolbox dependency: the ownership and gap rules run under the native
 * test compiler. transitions_cmd.c supplies the shared block in ordinary
 * application context; resident and Open Transport callbacks never call it.
 */
#ifndef NOW_TRANSITION_COORDINATOR_H
#define NOW_TRANSITION_COORDINATOR_H

#include "event_read.h"

typedef enum {
    kNowInvalidationSampled = 0,
    kNowInvalidationGap = 1,
    kNowInvalidationUnknown = 2
} NowInvalidationQuality;

typedef struct {
    NowEventU32 generation;
    NowEventU32 structure;
    NowEventU32 front;
    NowEventU32 menus;
    NowEventU32 finder;
    NowEventU32 content;
    NowEventU32 lost;
    NowInvalidationQuality quality;
} NowMirrorInvalidation;

typedef struct {
    NowEventBlock ledger;
    NowEventU32 source_cursor;
    NowEventU32 source_dropped;
    NowEventU32 generation;
    NowEventU32 structure_generation;
    NowEventU32 front_generation;
    NowEventU32 menu_generation;
    NowEventU32 finder_generation;
    NowEventU32 content_generation;
    NowEventU32 announced_generation;
    NowEventU32 unannounced_lost;
    NowInvalidationQuality unannounced_quality;
    int bound;
} NowTransitionCoordinator;

void now_transition_coordinator_init(NowTransitionCoordinator *coordinator);

/* Copies at most max_records and advances the RESIDENT reader cursor once.
 * A return value is the number copied, not the number of invalidations. */
unsigned long now_transition_coordinator_ingest(
    NowTransitionCoordinator *coordinator, NowEventBlock *source,
    unsigned long max_records);

/* One coalesced cumulative generation event. Returns 0 when no domain moved. */
int now_transition_coordinator_take_invalidation(
    NowTransitionCoordinator *coordinator, NowMirrorInvalidation *out);

const NowEventBlock *now_transition_coordinator_ledger(
    const NowTransitionCoordinator *coordinator);
void now_transition_coordinator_commit(NowTransitionCoordinator *coordinator,
                                       NowEventU32 next);

#endif /* NOW_TRANSITION_COORDINATOR_H */
