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
    /* Two text lines per row: bold title over a quiet subtitle. 30
       rather than 32 since Chat made eleven nav rows: at the 430-high
       minimum (a 640x480 screen leaves no room to grow the window),
       11x32 plus the pinned pair overran the divider. The baselines
       (13/25) still fit. */
    kWorkshopSidebarRowHeight = 30,
    /* The compact density: the icon and the title, no subtitle. 18 is
       the classic small-icon list row - the icon still fits at its
       native 16, which is why compact keeps it rather than becoming a
       bare text list. */
    kWorkshopSidebarCompactRowHeight = 18,
    kWorkshopGrowBoxSize = 15,

    /* A real scroll bar's width. The rail reserves it only when the nav
       rows overflow, so nothing is spent on chrome at the sizes where
       every row already fits. */
    kWorkshopRailScrollWidth = 16,

    /* Non-pinned modules; Preferences, Logs and Connection are pinned
       below the divider and are not among these. */
    /* Every module except the three pinned at the foot. Adding a module
       and forgetting this is not a cosmetic slip: the rail indexes
       nav_rows[], so a count one short reads PAST THE ARRAY and lays the
       new row out over whatever follows it in the struct. That is
       exactly what happened when Networking went in on 2026-08-01, and
       the assert in workshop_sidebar.c is why it cannot happen quietly
       again. */
    kWorkshopNavRows = 11
};

/* What the rail looks like right now: the person's density choice and
   how far the nav list is scrolled. Passed in rather than read from
   prefs here, because this file must stay free of everything but
   arithmetic - it is compiled by the host cc for the native test. */
typedef struct WorkshopRailSpec {
    Boolean compact;     /* one line per row instead of two */
    short scroll_top;    /* first visible nav row; clamped on the way in */
} WorkshopRailSpec;

typedef struct WorkshopLayout {
    Rect sidebar;       /* the whole rail, window-background gray */
    Rect rail_list;     /* one framed white panel holding every row */

    /* nav_rows[i] is the i-th VISIBLE SLOT, not the i-th module. Which
       module a slot shows is the rail's business: the person's order
       runs through it, and scroll_top offsets it. This used to be
       indexed by module ID directly, and anything still doing that is
       reading the wrong row the moment the list is scrolled or
       rearranged. Slots at or past nav_visible are zeroed, so a stale
       read draws nothing rather than landing on top of a real row. */
    Rect nav_rows[kWorkshopNavRows];
    short nav_visible;    /* slots that fit; <= kWorkshopNavRows */
    short nav_scroll_top; /* the spec's scroll_top, clamped to fit */
    Boolean rail_scrolls; /* true when the nav list overflows its space */
    Rect nav_scroll;      /* the scroll bar; EMPTY unless rail_scrolls */

    Rect conn_divider;  /* one-pixel rule above the pinned group */
    Rect prefs_row;     /* Preferences, first of the pinned group */
    Rect logs_row;      /* Logs, pinned just above Connection */
    Rect conn_row;      /* Connection, pinned at the panel's bottom */
    short row_height;   /* the density in effect, rich or compact */

    Rect header;        /* module header placard */
    Rect body;          /* module content */
    Rect status;        /* bottom status placard */
    Rect grow_safe;     /* corner square that status text must not enter */
} WorkshopLayout;

/* rail may be NULL, which means the rich density unscrolled - the shape
   this window had before either was a choice. */
void workshop_layout_compute(const Rect *content, const WorkshopRailSpec *rail,
                             WorkshopLayout *out);

#endif /* NOW_WORKSHOP_LAYOUT_H */
