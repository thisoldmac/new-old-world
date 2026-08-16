/* Native test for the rail's arrangement arithmetic. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src workshop_order_test.c \
          ../src/workshop/workshop_order.c -o workshop_order_test \
          && ./workshop_order_test

   The interesting half is the DEFAULT ORDER: it is a curation, and a
   curation that is only readable by running the app is a curation nobody
   checks. What is asserted here is what the table has to be true of - a
   permutation, with the adjacencies workshop_order.c argues for - not the
   exact list, which is a judgement and moves.

   The other half is what a saved arrangement is allowed to do to it: an
   order is ALWAYS a permutation of the nav range once adopted, whatever
   was on disk. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "workshop_order.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* Every nav id exactly once, and nothing else. The one property that
   makes an order safe to index a rail with. */
static int is_permutation(const short *order)
{
    char seen[kWorkshopNavRows + 1];
    int i;

    memset(seen, 0, sizeof seen);
    for (i = 0; i < kWorkshopNavRows; ++i) {
        short id = order[i];

        if (id < 1 || id > kWorkshopNavRows || seen[id]) {
            return 0;
        }
        seen[id] = 1;
    }
    return 1;
}

static int adjacent(const short *order, short a, short b)
{
    short pa = workshop_order_pos(order, a);
    short pb = workshop_order_pos(order, b);

    return pa >= 0 && pb >= 0 && pb == (short)(pa + 1);
}

int main(void)
{
    short order[kWorkshopNavRows];
    int i;

    /* The default table itself. */
    check(is_permutation(k_workshop_default_order),
          "the default order is a permutation of the nav range");
    check(k_workshop_default_order[0] == kWorkshopScreenshots,
          "the default order opens on the picture of the machine");
    check(k_workshop_default_order[kWorkshopNavRows - 1] == kWorkshopMCP,
          "MCP is last: the host keeps it in a footer this rail has not "
          "got");

    /* The adjacencies workshop_order.c argues for in prose. A default
       order is a claim about which pages answer the next question about
       the same subject, and these are the pairs that claim was made
       about; the rest of the sequence is free to move. */
    check(adjacent(k_workshop_default_order, kWorkshopFiles, kWorkshopCloud),
          "Files then Cloud: what the machines exchange, then what of the "
          "cloud joins it");
    check(adjacent(k_workshop_default_order, kWorkshopProcesses,
                   kWorkshopMirror),
          "Processes then Mirror: what is running, then what it has on "
          "screen");
    check(adjacent(k_workshop_default_order, kWorkshopConsole,
                   kWorkshopChat),
          "Console then Chat: the two pages that DO things to the machine");
    check(adjacent(k_workshop_default_order, kWorkshopHardware,
                   kWorkshopDiagnostics),
          "Hardware then Diagnostics: what the machine is, then what it "
          "can measure about itself");

    /* It is not the enum order. This is the whole point of I7 - the rail
       came up in the order the pages were WRITTEN, which is a history
       rather than a curation - and it is the check that catches a
       default table quietly reverting to the identity. */
    {
        int same = 1;

        for (i = 0; i < kWorkshopNavRows; ++i) {
            if (k_workshop_default_order[i] != (short)(i + 1)) {
                same = 0;
                break;
            }
        }
        check(!same, "the default order is a curation, not the enum order");
    }

    /* Seeding. */
    memset(order, 0, sizeof order);
    workshop_order_defaults(order);
    check(memcmp(order, k_workshop_default_order, sizeof order) == 0,
          "defaults seed exactly the table");

    /* No saved record at all - what a machine that has never run this
       version has - is the default, not an empty rail. */
    workshop_order_adopt(NULL, 0, order);
    check(memcmp(order, k_workshop_default_order, sizeof order) == 0,
          "a NULL saved order seeds the default");

    /* An all-zero record is what every file written before the field
       existed carries, and it must mean the same thing. */
    {
        /* The record's own width, which is a fixed 24 shorts (prefs.c,
           format 19) and deliberately wider than the nav range. Spelled
           out here rather than included: prefs.h is Toolbox-bound and
           this test is not. */
        short saved[24];

        memset(saved, 0, sizeof saved);
        workshop_order_adopt(saved, 24, order);
        check(memcmp(order, k_workshop_default_order, sizeof order) == 0,
              "an all-zero saved order seeds the default");
    }

    /* A real arrangement survives intact. */
    {
        short saved[kWorkshopNavRows];

        for (i = 0; i < kWorkshopNavRows; ++i) {
            saved[i] = (short)(kWorkshopNavRows - i);
        }
        workshop_order_adopt(saved, kWorkshopNavRows, order);
        check(memcmp(order, saved, sizeof saved) == 0,
              "a saved permutation is adopted unchanged");
    }

    /* A record from before a page existed: the saved part keeps its
       arrangement and the newcomer arrives in DEFAULT order rather than
       enum order, which is what stops a page added later landing
       somewhere the curation never put it. */
    {
        short saved[kWorkshopNavRows];
        /* Chosen so the two fills DISAGREE: the curation puts Web ahead
           of Hardware and the enum puts Hardware (5) ahead of Web (14).
           A pair the two orders agree on proves nothing here, which is
           exactly what the first version of this check picked. */
        short missing_a = kWorkshopWeb;
        short missing_b = kWorkshopHardware;
        short n = 0;

        for (i = 0; i < kWorkshopNavRows; ++i) {
            short id = (short)(i + 1);

            if (id != missing_a && id != missing_b) {
                saved[n++] = id;
            }
        }
        workshop_order_adopt(saved, n, order);
        check(is_permutation(order),
              "a short saved order still adopts as a permutation");
        check(order[kWorkshopNavRows - 2] == missing_a
                  && order[kWorkshopNavRows - 1] == missing_b,
              "pages missing from a saved order arrive in default order");
    }

    /* Garbage: out-of-range ids, repeats, and the pinned ids that must
       never appear here. Nothing is trusted, and the answer is still a
       permutation. */
    {
        short saved[kWorkshopNavRows];

        for (i = 0; i < kWorkshopNavRows; ++i) {
            saved[i] = (short)((i % 2) ? kWorkshopConnection : -3);
        }
        saved[0] = kWorkshopChat;
        saved[1] = kWorkshopChat;
        workshop_order_adopt(saved, kWorkshopNavRows, order);
        check(is_permutation(order),
              "a corrupt saved order still adopts as a permutation");
        check(order[0] == kWorkshopChat,
              "the one legible id in a corrupt record is honoured");
    }

    /* Moves. `to` counts positions BEFORE the lift, which is what a drop
       point between two visible rows means. */
    {
        short before[kWorkshopNavRows];

        workshop_order_defaults(order);
        memcpy(before, order, sizeof before);

        workshop_order_move(order, 0, 3);
        check(order[2] == before[0], "a row moved down lands before the drop");
        check(order[0] == before[1], "the rows above it slide up");
        check(is_permutation(order), "a move leaves a permutation");

        workshop_order_defaults(order);
        workshop_order_move(order, 5, 1);
        check(order[1] == before[5], "a row moved up lands at the drop");
        check(order[2] == before[1], "the rows below it slide down");

        workshop_order_defaults(order);
        workshop_order_move(order, 4, 4);
        check(memcmp(order, before, sizeof before) == 0,
              "a drop where the row already is changes nothing");
        workshop_order_move(order, 4, 5);
        check(memcmp(order, before, sizeof before) == 0,
              "a drop just below itself is the same position");

        workshop_order_defaults(order);
        workshop_order_move(order, -1, 3);
        workshop_order_move(order, 0, kWorkshopNavRows + 4);
        workshop_order_move(order, kWorkshopNavRows, 0);
        check(memcmp(order, before, sizeof before) == 0,
              "out-of-range moves are refused rather than clamped");
    }

    /* Positions, including the ones that are not in the arrangement at
       all: the pinned trio lives below the divider and must answer -1,
       because a caller that treats -1 as a slot index writes into the
       rail's rectangles. */
    workshop_order_defaults(order);
    for (i = 0; i < kWorkshopNavRows; ++i) {
        check(workshop_order_pos(order, order[i]) == i,
              "a page is found where it sits");
    }
    check(workshop_order_pos(order, kWorkshopPreferences) == -1
              && workshop_order_pos(order, kWorkshopLogs) == -1
              && workshop_order_pos(order, kWorkshopConnection) == -1,
          "the pinned group is not in the arrangement");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("workshop_order: all checks passed\n");
    return EXIT_SUCCESS;
}
