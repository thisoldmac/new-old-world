#ifndef NOW_SOFTWARE_LAYOUT_H
#define NOW_SOFTWARE_LAYOUT_H

/* Pure rectangle arithmetic and text formatting for the Software page.
   No Toolbox calls live here, so the same file compiles under the host's
   cc for the native test (now-guest-ppc/tests/software_layout_test.c) - the
   pattern workshop_layout.c and processes_layout.c set. The page is the
   split-view sibling of Processes: a toolbar (domain popup + live search)
   over an item list on the left and a detail pane on the right. */

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
    kSwMargin = 12,           /* body edge to the panes */
    kSwPaneGap = 10,          /* list to detail */
    kSwToolbarHeight = 20,    /* the popup / search row */
    kSwToolbarGap = 8,        /* toolbar to the panes */
    kSwListWide = 300,
    kSwListNarrow = 250,
    kSwListNarrowBelow = 548, /* body width, not window width */
    kSwListMin = 200,         /* splitter clamp: list never thinner -
                                 Rescan + Show in Finder need 192 */
    kSwDetailMin = 190,       /* splitter clamp: detail never thinner */
    kSwButtonHeight = 20,
    kSwButtonGap = 10,
    kSwPopupWidth = 168,
    kSwSearchWidth = 150,
    kSwSearchLabel = 52,      /* "Search:" ahead of the field */
    kSwFactLabelWidth = 62,   /* right-aligned detail labels */
    kSwLineHeight = 16,

    /* Data Browser column widths; Name takes what is left. State holds
       "(off) running", so it is the widest fixed column. */
    kSwColVersion = 52,
    kSwColSize = 52,
    kSwColState = 74,

    kSwLaunchWidth = 76,
    kSwFrontWidth = 104,      /* "Bring to Front" */
    kSwQuitWidth = 60,
    kSwRevealWidth = 108,     /* "Show in Finder" */
    kSwRescanWidth = 74       /* "Rescan" / "Stop" */
};

typedef struct SoftwareLayout {
    Rect toolbar_popup;       /* domain selector (popup menu) */
    Rect toolbar_search;      /* live-filter edit field */
    Rect list;                /* the item Data Browser */
    Rect splitter;            /* the draggable gap between the panes */
    Rect rescan_btn;          /* under the list, left */
    Rect detail;              /* everything to the list's right */
    Rect d_title;             /* name + version + running */
    Rect d_kind;              /* type / creator */
    Rect d_size;
    Rect d_where;             /* full path, line 1 */
    Rect d_where2;            /* full path, wrap line */
    Rect d_modified;
    Rect launch_btn;          /* Launch or (running) hidden */
    Rect front_btn;           /* Bring to Front */
    Rect quit_btn;
    Rect reveal_btn;          /* Show in Finder - always present */
} SoftwareLayout;

void software_layout_compute(const Rect *body, SoftwareLayout *out);

/* The same geometry with a person-chosen list width - the splitter's
   drag hands its result here. list_w <= 0 falls back to the default;
   any value is clamped so both panes keep a usable minimum
   (kSwListMin / kSwDetailMin), so a wild drag cannot wedge a pane
   shut. */
void software_layout_compute_split(const Rect *body, short list_w,
                                   SoftwareLayout *out);

/* "92K", "1.1M" - forks summed, classic style, ASCII only. */
void sw_size_text(long bytes, char *out, long cap);

/* "APPL / ttxt" from a Finder type and creator; any unprintable byte
   becomes a period so a garbage 4CC cannot smuggle control bytes into
   DrawString. */
void sw_kind_text(unsigned long type, unsigned long creator,
                  char *out, long cap);

/* The bottom-placard line for a domain: counts when settled, the honest
   in-progress text while a sweep runs. `off` is the disabled count for
   the folder domains (-1 = the domain has no off state, e.g. apps). */
void sw_status_text(const char *domain_label, int shown, int total,
                    int off, Boolean sweeping, char *out, long cap);

#endif /* NOW_SOFTWARE_LAYOUT_H */
