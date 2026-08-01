#ifndef NOW_CLOUD_LAYOUT_H
#define NOW_CLOUD_LAYOUT_H

/* The iCloud page's geometry, pure so the host cc can test it: click
   and draw read the same rectangles and cannot disagree. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef struct Rect { short top, left, bottom, right; } Rect;
#endif

typedef struct {
    Rect popup;                       /* the service dropdown */
    Rect refresh_btn;
    Rect list;                        /* the Data Browser */
    Rect detail;                      /* the card pane beside it */
    Rect detail_text;                 /* where card rows draw, inset */
    Rect save_btn;                    /* bottom of the detail pane */
    Rect status;                      /* one line under both panes */
} CloudLayout;

void cloud_layout_compute(const Rect *body, CloudLayout *r);

#endif /* NOW_CLOUD_LAYOUT_H */
