#include "workshop_layout.h"

/* Every rectangle the Workshop draws or hit-tests comes from here, so
   click, draw, and grow handlers can never disagree about where a thing
   is. Plain field assignment throughout: SetRect is Toolbox, and this
   file also runs under the host's cc. */

enum {
    kRailMargin = 8,        /* rail edge to the white panel */
    kRowInset = 1,          /* panel frame to a row's band */
    kRowTopPad = 2,         /* panel top to the first row */
    kDividerGap = 5         /* divider sits this far above the pinned row */
};

static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void workshop_layout_compute(const Rect *content, WorkshopLayout *out)
{
    short width = (short)(content->right - content->left);
    short rail = (short)(width < kWorkshopRailCompactBelow
                             ? kWorkshopRailNarrow
                             : kWorkshopRailWide);
    short rail_right = (short)(content->left + rail);
    short row_left;
    short row_right;
    short row_top;
    int i;

    set_rect(&out->sidebar, content->left, content->top, rail_right,
             content->bottom);
    set_rect(&out->rail_list, (short)(content->left + kRailMargin),
             (short)(content->top + kRailMargin),
             (short)(rail_right - kRailMargin),
             (short)(content->bottom - kRailMargin));

    row_left = (short)(out->rail_list.left + kRowInset);
    row_right = (short)(out->rail_list.right - kRowInset);
    row_top = (short)(out->rail_list.top + kRowTopPad);
    for (i = 0; i < 4; ++i) {
        set_rect(&out->nav_rows[i], row_left, row_top, row_right,
                 (short)(row_top + kWorkshopSidebarRowHeight));
        row_top = (short)(row_top + kWorkshopSidebarRowHeight);
    }
    set_rect(&out->conn_row, row_left,
             (short)(out->rail_list.bottom - kRowInset
                     - kWorkshopSidebarRowHeight),
             row_right, (short)(out->rail_list.bottom - kRowInset));
    set_rect(&out->conn_divider, row_left,
             (short)(out->conn_row.top - kDividerGap), row_right,
             (short)(out->conn_row.top - kDividerGap + 1));

    set_rect(&out->header, rail_right, content->top, content->right,
             (short)(content->top + kWorkshopHeaderHeight));
    set_rect(&out->status, rail_right,
             (short)(content->bottom - kWorkshopStatusHeight),
             content->right, content->bottom);
    set_rect(&out->body, rail_right, out->header.bottom, content->right,
             out->status.top);
    set_rect(&out->grow_safe,
             (short)(content->right - kWorkshopGrowBoxSize),
             (short)(content->bottom - kWorkshopGrowBoxSize),
             content->right, content->bottom);
}
