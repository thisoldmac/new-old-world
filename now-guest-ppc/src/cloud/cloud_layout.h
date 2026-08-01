#ifndef NOW_CLOUD_LAYOUT_H
#define NOW_CLOUD_LAYOUT_H

/* The iCloud page's geometry, pure so the host cc can test it: click
   and draw read the same rectangles and cannot disagree. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect { short top, left, bottom, right; } Rect;
typedef unsigned char Boolean;
#endif

typedef struct {
    Rect popup;                       /* the service dropdown */
    Rect toolbar_search;              /* the live filter, beside the
                                          popup — hand-drawn, not a
                                          control (the WaitNextEvent app
                                          cannot host an inline edit-text
                                          control; software_module.c's
                                          reason, unchanged here) */
    Rect refresh_btn;
    Rect up_btn;                      /* drive mode only: in the toolbar
                                          row, beside refresh; empty
                                          (zero area) outside drive mode */
    Rect list;                        /* the Data Browser: full body
                                          width in drive mode, left half
                                          otherwise */
    Rect detail;                      /* the card pane beside it; empty
                                          in drive mode — there is no
                                          card, the list owns the row */
    Rect detail_text;                 /* where card rows draw, inset;
                                          empty in drive mode */
    Rect save_btn;                    /* bottom of the detail pane;
                                          empty in drive mode (Up moves
                                          to up_btn, in the toolbar) */
    Rect status;                      /* one line under both panes */
} CloudLayout;

/* drive_mode picks which of the two layouts above cloud_draw's and
   cloud_click's rectangles actually are; both modes fill every field
   so a caller never needs to know which one ran. */
void cloud_layout_compute(const Rect *body, Boolean drive_mode,
                          CloudLayout *r);

#endif /* NOW_CLOUD_LAYOUT_H */
