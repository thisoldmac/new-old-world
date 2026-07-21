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
    for (i = 0; i < 3; ++i) {
        CHECK(contains(&lay->rail_list, &lay->nav_rows[i]),
              "module row inside panel");
    }
    CHECK(contains(&lay->rail_list, &lay->conn_row),
          "connection row inside panel");
    CHECK(contains(&lay->rail_list, &lay->conn_divider),
          "divider inside panel");

    /* The right pane and the rail never overlap, and the pane's three
       bands stack without touching. */
    CHECK(disjoint(&lay->sidebar, &lay->header), "rail vs header");
    CHECK(disjoint(&lay->sidebar, &lay->body), "rail vs body");
    CHECK(disjoint(&lay->sidebar, &lay->status), "rail vs status");
    CHECK(disjoint(&lay->header, &lay->body), "header vs body");
    CHECK(disjoint(&lay->body, &lay->status), "body vs status");
    for (i = 0; i < 2; ++i) {
        CHECK(disjoint(&lay->nav_rows[i], &lay->nav_rows[i + 1]),
              "module rows do not overlap");
    }
    CHECK(disjoint(&lay->nav_rows[2], &lay->conn_divider),
          "last module row vs divider");
    CHECK(disjoint(&lay->conn_divider, &lay->conn_row),
          "divider vs connection row");
    CHECK(lay->conn_divider.top > lay->nav_rows[2].bottom,
          "divider below the module rows");
    CHECK(lay->conn_divider.bottom <= lay->conn_row.top,
          "divider above the pinned row");

    /* The fixed chrome heights the spec names. */
    CHECK(height(&lay->header) == kWorkshopHeaderHeight, "header is 38");
    CHECK(height(&lay->status) == kWorkshopStatusHeight, "status is 23");
    CHECK(lay->header.top == content->top, "header at the top");
    CHECK(lay->status.bottom == content->bottom, "status at the bottom");
    CHECK(lay->header.right == content->right, "header reaches the edge");

    /* Row geometry: two-line rows, connection pinned at the bottom. */
    for (i = 0; i < 3; ++i) {
        CHECK(height(&lay->nav_rows[i]) == kWorkshopSidebarRowHeight,
              "module row height");
    }
    CHECK(height(&lay->conn_row) == kWorkshopSidebarRowHeight,
          "connection row height");
    CHECK(lay->conn_row.bottom >= lay->rail_list.bottom - 2,
          "connection pinned at the panel bottom");

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

int main(void)
{
    Rect content;
    WorkshopLayout lay;

    /* Standard content at 800x600. */
    content.left = 0;
    content.top = 0;
    content.right = kWorkshopStdContentW;
    content.bottom = kWorkshopStdContentH;
    workshop_layout_compute(&content, &lay);
    check_common(&content, &lay, "standard");
    check(width(&lay.sidebar) == kWorkshopRailWide,
          "standard: rail at full width");

    /* Minimum content. */
    content.right = kWorkshopMinContentW;
    content.bottom = kWorkshopMinContentH;
    workshop_layout_compute(&content, &lay);
    check_common(&content, &lay, "minimum");
    check(width(&lay.sidebar) == kWorkshopRailNarrow,
          "minimum: rail compacts");

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
        workshop_layout_compute(&zero, &at_zero);
        workshop_layout_compute(&moved, &shifted);
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
