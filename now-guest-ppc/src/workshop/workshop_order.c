#include "workshop_order.h"

#include <string.h>

/* The order a rail starts in, and the argument for it.

   Until now an unseeded rail came up in ENUM order, which is the order
   the pages were WRITTEN in - Screenshots, Files, Console, Processes,
   Hardware, Software, MCP - and that is a history, not a curation. The
   ids are untouched here and must stay untouched: they are a saved
   preference and a wire identity, and renumbering one silently moves
   somebody's arrangement (docs/adding-a-workshop-module.md).

   The host's ModuleRegistry.standardDefinitions argues its list the same
   way, page by page, and this rail adopts that curation so a person
   driving one machine from the other reads the same shape twice. The
   guest-specific departures are called out below; they exist because the
   two apps do not have the same set of pages or the same furniture.

     - Screen(shots) first: the picture of the machine is what a person
       opens this app to see.
     - Files second, and Cloud immediately after it, because they are one
       subject seen twice: Files is what the two machines exchange, iCloud
       is what of the cloud joins that exchange.
     - Processes, then Mirror: what is RUNNING, then what those programs
       have on screen. The next question about the same subject.
     - Console and Chat together: the two pages that DO things to the
       machine, one through a verb table and one through a model. Both
       come after the pages that only LOOK at it.
     - Web and Development after them - services this machine offers out,
       rather than questions asked of it.
     - Hardware, then Diagnostics, then Networking: what the machine IS,
       what it can MEASURE about itself, and what it says about its own
       link. A person chasing a slow transfer reads the three together.
       (The host calls the first of these Census; it is the same page.)
     - Software last of the facts pages, as on the host.
     - MCP at the foot of the list. On the host it is FOOTER furniture,
       because it is about the near side rather than about the machine
       being driven; this rail's footer is the pinned trio and cannot
       take a fourth, so the page ends up at the bottom of the nav list -
       the nearest honest place, and the one guest-specific departure
       that is a layout constraint rather than a judgement.

   Preferences, Logs and Connection are not here at all: they are pinned
   below the divider by workshop_layout.c and are not the person's to
   rearrange. */
const short k_workshop_default_order[kWorkshopNavRows] = {
    kWorkshopScreenshots,
    kWorkshopFiles,
    kWorkshopCloud,
    kWorkshopProcesses,
    kWorkshopMirror,
    kWorkshopConsole,
    kWorkshopChat,
    kWorkshopWeb,
    kWorkshopDevelopment,
    kWorkshopHardware,
    kWorkshopDiagnostics,
    kWorkshopNetworking,
    kWorkshopSoftware,
    kWorkshopMCP
};

void workshop_order_defaults(short *order)
{
    short i;

    if (order == NULL) {
        return;
    }
    for (i = 0; i < kWorkshopNavRows; ++i) {
        order[i] = k_workshop_default_order[i];
    }
}

void workshop_order_adopt(const short *saved, short saved_count, short *order)
{
    char seen[kWorkshopNavRows + 1];
    short n = 0;
    short i;

    if (order == NULL) {
        return;
    }
    if (saved == NULL) {
        workshop_order_defaults(order);
        return;
    }
    memset(seen, 0, sizeof seen);
    for (i = 0; i < saved_count && n < kWorkshopNavRows; ++i) {
        short id = saved[i];

        if (id >= 1 && id <= kWorkshopNavRows && !seen[id]) {
            seen[id] = 1;
            order[n++] = id;
        }
    }
    /* The tail is filled in DEFAULT order rather than enum order, so a
       page added after an arrangement was saved lands where the curation
       above would have put it relative to the other newcomers - not in
       the order the enum happens to declare them. */
    for (i = 0; i < kWorkshopNavRows && n < kWorkshopNavRows; ++i) {
        short id = k_workshop_default_order[i];

        if (!seen[id]) {
            seen[id] = 1;
            order[n++] = id;
        }
    }
}

void workshop_order_move(short *order, short from, short to)
{
    short moved;
    short i;

    if (order == NULL || from < 0 || from >= kWorkshopNavRows || to < 0
        || to > kWorkshopNavRows) {
        return;
    }
    if (to > from) {
        --to;                         /* the lift closed the gap */
    }
    if (to == from) {
        return;
    }
    moved = order[from];
    if (to < from) {
        for (i = from; i > to; --i) {
            order[i] = order[i - 1];
        }
    } else {
        for (i = from; i < to; ++i) {
            order[i] = order[i + 1];
        }
    }
    order[to] = moved;
}

short workshop_order_pos(const short *order, short module)
{
    short i;

    if (order == NULL) {
        return -1;
    }
    for (i = 0; i < kWorkshopNavRows; ++i) {
        if (order[i] == module) {
            return i;
        }
    }
    return -1;
}
