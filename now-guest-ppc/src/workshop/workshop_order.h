#ifndef NOW_WORKSHOP_ORDER_H
#define NOW_WORKSHOP_ORDER_H

#include "workshop_layout.h"      /* kWorkshopNavRows, and Boolean off-target */
#include "workshop_module_ids.h"

/* The person's arrangement of the nav rows, as pure arithmetic over page
   ids. No Toolbox call lives here, so this file compiles under the host's
   cc for now-guest-ppc/tests/workshop_order_test.c - the same split
   workshop_layout.c makes for the rectangles, and the reason the DEFAULT
   ORDER below is something a test can read rather than something only a
   running rail knows.

   An order is always a permutation of 1..kWorkshopNavRows: every caller
   goes through workshop_order_adopt, which is what makes a truncated,
   corrupt, or simply older saved record cost nothing. */

/* The order a rail with no saved arrangement starts in. */
extern const short k_workshop_default_order[kWorkshopNavRows];

void workshop_order_defaults(short *order);

/* Whatever was on disk becomes a permutation: ids out of the nav range
   and repeats are dropped, then anything MISSING is appended in default
   order. That is what makes a page added later simply arrive near where
   the curation puts it instead of invalidating the arrangement. */
void workshop_order_adopt(const short *saved, short saved_count,
                          short *order);

/* Lift one row out and drop it back in at `to`, everything between
   sliding up or down by one. `to` counts positions in the list BEFORE
   the lift, which is what a drop point between two visible rows means. */
void workshop_order_move(short *order, short from, short to);

/* Where a page sits in the arrangement, or -1 if it is not a nav row. */
short workshop_order_pos(const short *order, short module);

#endif /* NOW_WORKSHOP_ORDER_H */
