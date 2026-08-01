#ifndef NOW_WORKSHOP_LAYOUT_H
#define NOW_WORKSHOP_LAYOUT_H

/* Pure rectangle arithmetic for the Workshop window. No Toolbox calls
   live here, so the same file compiles under the host's cc for the
   native test (now-guest-ppc/tests/workshop_layout_test.c) - the pattern
   json.c established. The Rect definition below matches QuickDraw's
   field order exactly; on the target the real one is used. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect {
    short top;
    short left;
    short bottom;
    short right;
} Rect;
typedef unsigned char Boolean;
#endif

enum {
    kWorkshopMinContentW = 620,
    kWorkshopMinContentH = 430,
    kWorkshopStdContentW = 744,
    kWorkshopStdContentH = 478,

    /* The rail compacts when the window narrows toward the minimum,
       so the work pane keeps its share of a 640-wide screen. */
    kWorkshopRailWide = 160,
    kWorkshopRailNarrow = 128,
    kWorkshopRailCompactBelow = 660,

    kWorkshopHeaderHeight = 38,
    kWorkshopStatusHeight = 23,
    /* Two text lines per row: bold title over a quiet subtitle. */
    kWorkshopSidebarRowHeight = 32,
    kWorkshopGrowBoxSize = 15,

    /* Non-pinned modules; Logs and Connection are pinned below the
       divider and are not among these. */
    /* Every module except the two pinned at the foot (Logs and
       Connection). Adding a module and forgetting this is not a cosmetic
       slip: row_rect() indexes nav_rows[module - 1], so a count one
       short reads PAST THE ARRAY and lays the new row out over whatever
       follows it in the struct. That is exactly what happened when
       Networking went in on 2026-08-01, and the assert below is why it
       cannot happen quietly again. */
    kWorkshopNavRows = 10
};

typedef struct WorkshopLayout {
    Rect sidebar;       /* the whole rail, window-background gray */
    Rect rail_list;     /* one framed white panel holding every row */
    Rect nav_rows[kWorkshopNavRows];  /* Screenshots, Files, Console,
                                         Processes, Hardware, Software,
                                         MCP, Diagnostics, Networking,
                                         Mirror */
    Rect conn_divider;  /* one-pixel rule above the pinned pair */
    Rect logs_row;      /* Logs, pinned just above Connection */
    Rect conn_row;      /* Connection, pinned at the panel's bottom */
    Rect header;        /* module header placard */
    Rect body;          /* module content */
    Rect status;        /* bottom status placard */
    Rect grow_safe;     /* corner square that status text must not enter */
} WorkshopLayout;

void workshop_layout_compute(const Rect *content, WorkshopLayout *out);

#endif /* NOW_WORKSHOP_LAYOUT_H */
