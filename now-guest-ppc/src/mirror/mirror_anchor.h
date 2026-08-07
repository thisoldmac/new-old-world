#ifndef NOW_MIRROR_ANCHOR_H
#define NOW_MIRROR_ANCHOR_H

/* Reading the P1 hot path's own counters out of the shared table.
 *
 * Toolbox-free on purpose, like mirror_facts.h and the layout half: the
 * whole of this decision is arithmetic over a struct the resident wrote,
 * so it compiles with the host `cc` and is tested here rather than only
 * on a Macintosh (tests/mirror_anchor_test.c). Nothing in it allocates,
 * and nothing in it calls the Toolbox.
 *
 * WHY IT EXISTS. `ax_oracle_not_found` is the scene's word for "no
 * anchor slot claims this process's partition", and on 2026-08-07 it was
 * reported for every foreign process on one machine and for only the
 * faceless ones on another - the same commit, the same base image, hours
 * apart. Neither report could be advanced, because "the filter never ran
 * in that process's context" and "it ran and the partition read
 * disagreed" produce the identical word and the resident's own evidence
 * for telling them apart was unreadable from either face. */

#include "mirror_facts.h"
#include "peek_table.h"

/* Fill `out` from `table`. `now_ticks` is the caller's TickCount, passed
   in rather than read here so the whole function stays pure.
   `slot_budget` bounds how many occupied slots are reported; the rest
   are counted into `slots_omitted` rather than dropped silently. A
   budget of 0 means "as many as the table can hold". */
void now_mirror_anchor_read(const NowPeekTable *table,
                            unsigned long now_ticks,
                            int slot_budget,
                            MirrorAnchorFacts *out);

/* How many occupied slots a reply of `cap` bytes can afford after
   `used` bytes are already spent. Stated once, here, because the JSON
   emitter and any test that reasons about truncation must agree; a
   second copy of this arithmetic is how a list comes back short and
   says it is whole. */
int now_mirror_anchor_slot_budget(long cap, long used);

#endif /* NOW_MIRROR_ANCHOR_H */
