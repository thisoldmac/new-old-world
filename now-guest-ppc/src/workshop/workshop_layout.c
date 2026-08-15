#include "workshop_layout.h"

#include <stddef.h>       /* NULL: the rail spec is optional */

/* Every rectangle the Workshop draws or hit-tests comes from here, so
   click, draw, and grow handlers can never disagree about where a thing
   is. Plain field assignment throughout: SetRect is Toolbox, and this
   file also runs under the host's cc. */

enum {
    kRailMargin = 8,        /* rail edge to the white panel */
    kRowInset = 1,          /* panel frame to a row's band */
    kRowTopPad = 2,         /* panel top to the first row */
    kDividerGap = 5,        /* divider sits this far above the pinned row */
    kPinnedRows = 3         /* Preferences, Logs, Connection */
};

static void set_rect(Rect *r, short left, short top, short right,
                     short bottom)
{
    r->left = left;
    r->top = top;
    r->right = right;
    r->bottom = bottom;
}

void workshop_layout_compute(const Rect *content, const WorkshopRailSpec *rail_spec,
                             WorkshopLayout *out)
{
    short width = (short)(content->right - content->left);
    Boolean collapsed = (Boolean)(rail_spec != NULL && rail_spec->collapsed);
    /* Collapsed wins over the width rule: a rail showing only icons needs
       the same room whether the window is wide or narrow. */
    short rail = (short)(collapsed
                             ? kWorkshopRailCollapsed
                             : (width < kWorkshopRailCompactBelow
                                    ? kWorkshopRailNarrow
                                    : kWorkshopRailWide));
    short rail_right = (short)(content->left + rail);
    short row_h;
    short scroll_top = (short)(rail_spec != NULL ? rail_spec->scroll_top : 0);
    short row_left;
    short row_right;
    short nav_top;
    short nav_limit;
    short visible;
    short max_top;
    short row_top;
    int i;

    row_h = collapsed ? kWorkshopSidebarIconRowHeight
                      : kWorkshopSidebarRowHeight;
    out->row_height = row_h;
    out->collapsed = collapsed;

    set_rect(&out->sidebar, content->left, content->top, rail_right,
             content->bottom);
    set_rect(&out->rail_list, (short)(content->left + kRailMargin),
             (short)(content->top + kRailMargin),
             (short)(rail_right - kRailMargin),
             (short)(content->bottom - kRailMargin));

    row_left = (short)(out->rail_list.left + kRowInset);
    row_right = (short)(out->rail_list.right - kRowInset);

    /* The pinned group is laid out FIRST, upward from the panel's foot,
       because it is what the nav list has left over. Doing it the other
       way round is how the rows once ran past the divider. */
    set_rect(&out->conn_row, row_left,
             (short)(out->rail_list.bottom - kRowInset - row_h),
             row_right, (short)(out->rail_list.bottom - kRowInset));
    /* Logs and Preferences are pinned too, stacked above Connection: the
       three make one group below the divider, the way the reference pins
       the link state and its log together at the foot of the rail. */
    set_rect(&out->logs_row, row_left, (short)(out->conn_row.top - row_h),
             row_right, out->conn_row.top);
    set_rect(&out->prefs_row, row_left, (short)(out->logs_row.top - row_h),
             row_right, out->logs_row.top);
    set_rect(&out->conn_divider, row_left,
             (short)(out->prefs_row.top - kDividerGap), row_right,
             (short)(out->prefs_row.top - kDividerGap + 1));

    /* Whatever is left above the divider is the nav list's. A slot count
       of zero is not representable - a rail showing no rows at all is
       worse than one row clipped - so it floors at 1 and the panel is
       allowed to overrun rather than vanish. */
    nav_top = (short)(out->rail_list.top + kRowTopPad);
    nav_limit = (short)(out->conn_divider.top - kDividerGap);
    visible = (short)((nav_limit - nav_top) / row_h);
    if (visible < 1) {
        visible = 1;
    }
    if (visible > kWorkshopNavRows) {
        visible = kWorkshopNavRows;
    }
    out->nav_visible = visible;
    out->rail_scrolls = (Boolean)(visible < kWorkshopNavRows);

    max_top = (short)(kWorkshopNavRows - visible);
    if (scroll_top > max_top) {
        scroll_top = max_top;
    }
    if (scroll_top < 0) {
        scroll_top = 0;
    }
    out->nav_scroll_top = scroll_top;

    if (out->rail_scrolls) {
        set_rect(&out->nav_scroll,
                 (short)(row_right - kWorkshopRailScrollWidth), nav_top,
                 row_right, (short)(nav_top + visible * row_h));
        /* The rows give up exactly the bar's width; the bar's left edge
           doubles as their right, so the two share one line the way a
           scrolling list's do. */
        row_right = out->nav_scroll.left;
    } else {
        set_rect(&out->nav_scroll, 0, 0, 0, 0);
    }

    row_top = nav_top;
    for (i = 0; i < visible; ++i) {
        set_rect(&out->nav_rows[i], row_left, row_top, row_right,
                 (short)(row_top + row_h));
        row_top = (short)(row_top + row_h);
    }
    /* Slots nothing occupies are empty, not stale. A caller that walks
       the whole array draws nothing for them rather than painting a row
       from the last layout on top of a real one. */
    for (; i < kWorkshopNavRows; ++i) {
        set_rect(&out->nav_rows[i], 0, 0, 0, 0);
    }

    set_rect(&out->header, rail_right, content->top, content->right,
             (short)(content->top + kWorkshopHeaderHeight));
    /* The collapse button lives in the header rather than in the rail: it
       has to be in the same place, at the same size, in both states, and
       a 48-pixel rail has no room to spare. The header's text starts
       clear of it, which is why that offset is computed here instead of
       being a constant at the draw site. */
    set_rect(&out->rail_toggle,
             (short)(out->header.left + kWorkshopRailToggleInset),
             (short)(out->header.top
                     + (kWorkshopHeaderHeight - kWorkshopRailToggleSize) / 2),
             (short)(out->header.left + kWorkshopRailToggleInset
                     + kWorkshopRailToggleSize),
             (short)(out->header.top
                     + (kWorkshopHeaderHeight - kWorkshopRailToggleSize) / 2
                     + kWorkshopRailToggleSize));
    out->header_text_left = (short)(out->rail_toggle.right + 8);
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
