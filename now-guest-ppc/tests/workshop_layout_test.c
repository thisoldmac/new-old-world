/* Native test for the Workshop layout arithmetic. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src workshop_layout_test.c \
          ../src/workshop_layout.c -o workshop_layout_test \
          && ./workshop_layout_test

   Checks the two sizes the spec names - the 800x600 standard content
   and the minimum - plus an offset origin, because a layout that only
   works at (0,0) is a layout that breaks the first time someone hands
   it a real port rectangle. */

#include <stdio.h>
#include <stdlib.h>

#include "workshop_layout.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static int contains(const Rect *outer, const Rect *inner)
{
    return inner->left >= outer->left && inner->top >= outer->top
        && inner->right <= outer->right && inner->bottom <= outer->bottom;
}

static int disjoint(const Rect *a, const Rect *b)
{
    return a->right <= b->left || b->right <= a->left
        || a->bottom <= b->top || b->bottom <= a->top;
}

static int width(const Rect *r)
{
    return r->right - r->left;
}

static int height(const Rect *r)
{
    return r->bottom - r->top;
}

static void check_common(const Rect *content, const WorkshopLayout *lay,
                         const char *label)
{
    char what[128];
    int i;

#define CHECK(cond, text)                                             \
    do {                                                              \
        snprintf(what, sizeof what, "%s: %s", label, text);           \
        check((cond), what);                                          \
    } while (0)

    /* Everything stays inside the content area. */
    CHECK(contains(content, &lay->sidebar), "sidebar inside content");
    CHECK(contains(content, &lay->header), "header inside content");
    CHECK(contains(content, &lay->body), "body inside content");
    CHECK(contains(content, &lay->status), "status inside content");
    CHECK(contains(&lay->sidebar, &lay->rail_list),
          "panel inside sidebar");
    CHECK(lay->nav_visible >= 1 && lay->nav_visible <= kWorkshopNavRows,
          "visible slot count is sane");
    for (i = 0; i < lay->nav_visible; ++i) {
        CHECK(contains(&lay->rail_list, &lay->nav_rows[i]),
              "module row inside panel");
    }
    /* Slots past the visible count are empty, so a caller that walks the
       whole array cannot paint a stale row over a live one. */
    for (i = lay->nav_visible; i < kWorkshopNavRows; ++i) {
        CHECK(width(&lay->nav_rows[i]) == 0 && height(&lay->nav_rows[i]) == 0,
              "unused slot is empty");
    }
    CHECK(contains(&lay->rail_list, &lay->prefs_row),
          "preferences row inside panel");
    CHECK(contains(&lay->rail_list, &lay->conn_row),
          "connection row inside panel");
    CHECK(contains(&lay->rail_list, &lay->logs_row),
          "logs row inside panel");
    CHECK(contains(&lay->rail_list, &lay->conn_divider),
          "divider inside panel");

    /* The right pane and the rail never overlap, and the pane's three
       bands stack without touching. */
    CHECK(disjoint(&lay->sidebar, &lay->header), "rail vs header");
    CHECK(disjoint(&lay->sidebar, &lay->body), "rail vs body");
    CHECK(disjoint(&lay->sidebar, &lay->status), "rail vs status");
    CHECK(disjoint(&lay->header, &lay->body), "header vs body");
    CHECK(disjoint(&lay->body, &lay->status), "body vs status");
    for (i = 0; i < lay->nav_visible - 1; ++i) {
        CHECK(disjoint(&lay->nav_rows[i], &lay->nav_rows[i + 1]),
              "module rows do not overlap");
    }
    CHECK(disjoint(&lay->nav_rows[lay->nav_visible - 1],
                   &lay->conn_divider),
          "last module row vs divider");
    CHECK(disjoint(&lay->conn_divider, &lay->prefs_row),
          "divider vs preferences row");
    CHECK(disjoint(&lay->prefs_row, &lay->logs_row),
          "preferences row vs logs row");
    CHECK(disjoint(&lay->logs_row, &lay->conn_row),
          "logs row vs connection row");
    /* The bug this whole file exists for: the nav list running past the
       divider and drawing on top of the pinned group. */
    CHECK(lay->conn_divider.top
              > lay->nav_rows[lay->nav_visible - 1].bottom,
          "divider below the module rows");
    CHECK(lay->conn_divider.bottom <= lay->prefs_row.top,
          "divider above the pinned group");
    CHECK(lay->prefs_row.bottom <= lay->logs_row.top,
          "preferences pinned directly above logs");
    CHECK(lay->logs_row.bottom <= lay->conn_row.top,
          "logs pinned directly above connection");

    /* The scroll bar exists exactly when the list overflows, takes its
       width from the rows rather than from the panel, and spans only the
       nav list - never the pinned group. */
    if (lay->rail_scrolls) {
        CHECK(contains(&lay->rail_list, &lay->nav_scroll),
              "scroll bar inside panel");
        CHECK(width(&lay->nav_scroll) == kWorkshopRailScrollWidth,
              "scroll bar is 16 wide");
        CHECK(lay->nav_scroll.left == lay->nav_rows[0].right,
              "scroll bar takes its width from the rows");
        CHECK(lay->nav_scroll.top == lay->nav_rows[0].top
                  && lay->nav_scroll.bottom
                         == lay->nav_rows[lay->nav_visible - 1].bottom,
              "scroll bar spans exactly the visible slots");
        CHECK(disjoint(&lay->nav_scroll, &lay->conn_divider),
              "scroll bar clear of the divider");
        CHECK(disjoint(&lay->nav_scroll, &lay->conn_row),
              "scroll bar clear of the pinned group");
    } else {
        CHECK(lay->nav_visible == kWorkshopNavRows,
              "no scroll bar means every row fits");
        CHECK(width(&lay->nav_scroll) == 0 && height(&lay->nav_scroll) == 0,
              "no scroll bar rect when nothing overflows");
        CHECK(lay->nav_rows[0].right == lay->rail_list.right - 1,
              "rows keep the full width when there is no bar");
    }
    CHECK(lay->nav_scroll_top >= 0
              && lay->nav_scroll_top <= kWorkshopNavRows - lay->nav_visible,
          "scroll position clamped to what can be shown");

    /* The fixed chrome heights the spec names. */
    CHECK(height(&lay->header) == kWorkshopHeaderHeight, "header is 38");
    CHECK(height(&lay->status) == kWorkshopStatusHeight, "status is 23");
    CHECK(lay->header.top == content->top, "header at the top");
    CHECK(lay->status.bottom == content->bottom, "status at the bottom");
    CHECK(lay->header.right == content->right, "header reaches the edge");

    /* Row geometry: every row is the height in effect, and the pinned
       group follows the nav rows rather than keeping its own. Two heights
       since the rich density was retired - expanded, and collapsed. */
    CHECK(lay->row_height == kWorkshopSidebarRowHeight
              || lay->row_height == kWorkshopSidebarIconRowHeight,
          "row height is one of the two the rail can be in");
    CHECK(!lay->collapsed
              || lay->row_height == kWorkshopSidebarIconRowHeight,
          "a collapsed rail always takes the icon row height");
    for (i = 0; i < lay->nav_visible; ++i) {
        CHECK(height(&lay->nav_rows[i]) == lay->row_height,
              "module row height");
    }
    CHECK(height(&lay->conn_row) == lay->row_height,
          "connection row height");
    CHECK(height(&lay->logs_row) == lay->row_height,
          "logs row height");
    CHECK(height(&lay->prefs_row) == lay->row_height,
          "preferences row height");
    CHECK(lay->conn_row.bottom >= lay->rail_list.bottom - 2,
          "connection pinned at the panel bottom");

    /* The collapse button sits inside the header, and the header's text
       starts clear of it - the two must never overlap, whichever state
       the rail is in. */
    CHECK(contains(&lay->header, &lay->rail_toggle),
          "collapse button inside the header");
    CHECK(width(&lay->rail_toggle) == kWorkshopRailToggleSize
              && height(&lay->rail_toggle) == kWorkshopRailToggleSize,
          "collapse button is square");
    CHECK(lay->header_text_left >= lay->rail_toggle.right,
          "header text starts clear of the button");
    CHECK(lay->header_text_left < lay->header.right,
          "header text starts inside the header");

    /* The grow box corner is exactly the classic 15x15, and the status
       placard knows to stay out of it. */
    CHECK(width(&lay->grow_safe) == kWorkshopGrowBoxSize
              && height(&lay->grow_safe) == kWorkshopGrowBoxSize,
          "grow corner is 15x15");
    CHECK(lay->grow_safe.right == content->right
              && lay->grow_safe.bottom == content->bottom,
          "grow corner in the corner");

    /* The body is the flexible region: it must dominate the pane. */
    CHECK(height(&lay->body) >= 300, "body keeps its height");
    CHECK(width(&lay->body) >= 440, "body keeps its width");

#undef CHECK
}

static void set_content(Rect *r, short w, short h)
{
    r->left = 0;
    r->top = 0;
    r->right = w;
    r->bottom = h;
}

int main(void)
{
    Rect content;
    WorkshopLayout lay;
    WorkshopRailSpec rail;

    /* Standard content at the spec size, expanded and unscrolled. NULL
       must mean exactly that. */
    set_content(&content, kWorkshopStdContentW, kWorkshopStdContentH);
    workshop_layout_compute(&content, NULL, &lay);
    check_common(&content, &lay, "standard");
    check(width(&lay.sidebar) == kWorkshopRailWide,
          "standard: rail at full width");
    check(lay.row_height == kWorkshopSidebarRowHeight,
          "standard: NULL spec means the expanded row height");
    {
        WorkshopLayout explicit_expanded;

        rail.collapsed = 0;
        rail.scroll_top = 0;
        workshop_layout_compute(&content, &rail, &explicit_expanded);
        check(explicit_expanded.nav_rows[0].bottom == lay.nav_rows[0].bottom
                  && explicit_expanded.conn_row.top == lay.conn_row.top
                  && explicit_expanded.nav_visible == lay.nav_visible,
              "standard: NULL spec matches an explicit expanded one");
    }
    check(!lay.rail_scrolls,
          "standard: every row fits, so nothing scrolls");

    /* Minimum content. */
    set_content(&content, kWorkshopMinContentW, kWorkshopMinContentH);
    workshop_layout_compute(&content, NULL, &lay);
    check_common(&content, &lay, "minimum");
    check(width(&lay.sidebar) == kWorkshopRailNarrow,
          "minimum: rail takes the narrow width");

    /* The whole argument for retiring the rich density: at the smallest
       window this app allows - the one a 640x480 screen forces - every
       nav row is on screen at once, with no scroll bar and nothing hidden
       behind one. This is the check that fails if anyone reinstates a
       taller row: 14 rows at 30 pixels do not fit here, which is why the
       choice went away rather than gaining a better default. */
    rail.collapsed = 0;
    rail.scroll_top = 0;
    workshop_layout_compute(&content, &rail, &lay);
    check_common(&content, &lay, "minimum expanded");
    check(lay.row_height == kWorkshopSidebarRowHeight,
          "minimum: rows take the one expanded height");
    check(lay.nav_visible == kWorkshopNavRows,
          "minimum: every nav row has a slot");
    check(!lay.rail_scrolls,
          "minimum: every row fits, so no bar squeezes the rail");

    /* Collapsed: a narrow rail of icon-height rows, at every window size,
       and the body gets back everything the rail gave up. */
    {
        WorkshopLayout wide;
        WorkshopLayout tight;

        set_content(&content, kWorkshopStdContentW, kWorkshopStdContentH);
        rail.collapsed = 0;
        rail.scroll_top = 0;
        workshop_layout_compute(&content, &rail, &wide);

        rail.collapsed = 1;
        workshop_layout_compute(&content, &rail, &tight);
        check_common(&content, &tight, "collapsed");
        check(tight.collapsed, "collapsed: the layout says so");
        check(width(&tight.sidebar) == kWorkshopRailCollapsed,
              "collapsed: the rail is the collapsed width");
        check(tight.row_height == kWorkshopSidebarIconRowHeight,
              "collapsed: rows take the icon height");
        check(width(&tight.body) > width(&wide.body),
              "collapsed: the body gains what the rail gave up");
        check(!tight.rail_scrolls,
              "collapsed: every row fits, so no bar squeezes the icons");

        /* The narrow-window rule must not shrink it further: an icon rail
           is the same size whatever the window is doing. */
        set_content(&content, kWorkshopMinContentW, kWorkshopMinContentH);
        workshop_layout_compute(&content, &rail, &tight);
        check_common(&content, &tight, "collapsed minimum");
        check(width(&tight.sidebar) == kWorkshopRailCollapsed,
              "collapsed: the narrow-window rule does not shrink it");
        check(!tight.rail_scrolls,
              "collapsed at the minimum: still no bar");
    }

    /* Scrolling: a spec that asks for an offset gets one, the slots move
       by exactly one row height per step, and an offset past the end is
       clamped rather than emptying the list. */
    {
        WorkshopLayout unscrolled;
        WorkshopLayout scrolled;
        WorkshopLayout overscrolled;

        /* Deliberately SHORTER than the minimum window: no window this
           app allows can overflow the rail any more, and the scrolling
           arithmetic still has to be right, because the next page added
           to the rail is the one that brings it back. Pure arithmetic
           takes any rectangle; the window manager is not consulted, and
           check_common is deliberately not run over these - it asserts
           the body sizes a REAL window guarantees. */
        set_content(&content, kWorkshopMinContentW, 300);
        rail.collapsed = 0;
        rail.scroll_top = 0;
        workshop_layout_compute(&content, &rail, &unscrolled);
        check(unscrolled.rail_scrolls,
              "a rail too short for its rows overflows");

        rail.scroll_top = 1;
        workshop_layout_compute(&content, &rail, &scrolled);
        check(scrolled.nav_scroll_top == 1, "scrolled: offset honoured");
        check(scrolled.nav_rows[0].top == unscrolled.nav_rows[0].top,
              "scrolled: the first slot stays put - the CONTENT moves");
        check(scrolled.nav_visible == unscrolled.nav_visible,
              "scrolled: the same number of slots");

        rail.scroll_top = 99;
        workshop_layout_compute(&content, &rail, &overscrolled);
        check(overscrolled.nav_scroll_top
                  == kWorkshopNavRows - overscrolled.nav_visible,
              "overscrolled: clamped to the last full page");

        rail.scroll_top = -5;
        workshop_layout_compute(&content, &rail, &overscrolled);
        check(overscrolled.nav_scroll_top == 0,
              "negative scroll clamps to the top");
    }
    set_content(&content, kWorkshopMinContentW, kWorkshopMinContentH);

    /* An offset origin must shift every rectangle rigidly. */
    {
        WorkshopLayout at_zero;
        WorkshopLayout shifted;
        Rect zero;
        Rect moved;
        const short dx = 40;
        const short dy = 60;

        zero.left = 0;
        zero.top = 0;
        zero.right = kWorkshopStdContentW;
        zero.bottom = kWorkshopStdContentH;
        moved.left = (short)(zero.left + dx);
        moved.top = (short)(zero.top + dy);
        moved.right = (short)(zero.right + dx);
        moved.bottom = (short)(zero.bottom + dy);
        workshop_layout_compute(&zero, NULL, &at_zero);
        workshop_layout_compute(&moved, NULL, &shifted);
        check(shifted.body.left == at_zero.body.left + dx
                  && shifted.body.top == at_zero.body.top + dy
                  && shifted.status.bottom == at_zero.status.bottom + dy
                  && shifted.conn_row.right == at_zero.conn_row.right + dx
                  && shifted.nav_rows[1].top == at_zero.nav_rows[1].top + dy,
              "offset origin shifts rigidly");
    }

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("workshop_layout: all checks passed\n");
    return EXIT_SUCCESS;
}
