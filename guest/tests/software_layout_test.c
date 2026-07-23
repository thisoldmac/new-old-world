/* Native test for the Software page's pure half. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src software_layout_test.c \
          ../src/software_layout.c -o software_layout_test \
          && ./software_layout_test

   Geometry at the standard and minimum body sizes plus an offset origin,
   then the formatters - including the unprintable-4CC case, because a
   garbage Finder type must not reach DrawString raw. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "software_layout.h"

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

static int width(const Rect *r) { return r->right - r->left; }
static int height(const Rect *r) { return r->bottom - r->top; }

static void check_common(const Rect *body, const SoftwareLayout *lay,
                         const char *label)
{
    char what[128];

#define CHECK(cond, text)                                             \
    do {                                                              \
        snprintf(what, sizeof what, "%s: %s", label, text);           \
        check((cond), what);                                          \
    } while (0)

    /* Everything inside the body. */
    CHECK(contains(body, &lay->toolbar_popup), "popup inside body");
    CHECK(contains(body, &lay->toolbar_search), "search inside body");
    CHECK(contains(body, &lay->list), "list inside body");
    CHECK(contains(body, &lay->detail), "detail inside body");
    CHECK(contains(body, &lay->rescan_btn), "rescan inside body");
    CHECK(contains(body, &lay->reveal_btn), "reveal inside body");

    /* Toolbar over the panes; popup left, search right, no overlap. */
    CHECK(lay->list.top >= lay->toolbar_popup.bottom, "list below toolbar");
    CHECK(lay->detail.top >= lay->toolbar_search.bottom,
          "detail below toolbar");
    CHECK(disjoint(&lay->toolbar_popup, &lay->toolbar_search),
          "popup and search do not overlap");
    CHECK(lay->toolbar_search.left > lay->toolbar_popup.right,
          "search is right of the popup");

    /* The two panes and their gap. */
    CHECK(disjoint(&lay->list, &lay->detail), "panes do not overlap");
    CHECK(lay->detail.left - lay->list.right == kSwPaneGap,
          "pane gap as specified");

    /* Detail facts stack in order and stay in the pane. */
    CHECK(contains(&lay->detail, &lay->d_title), "title in detail");
    CHECK(contains(&lay->detail, &lay->d_kind), "kind in detail");
    CHECK(contains(&lay->detail, &lay->d_size), "size in detail");
    CHECK(contains(&lay->detail, &lay->d_where), "where in detail");
    CHECK(contains(&lay->detail, &lay->d_where2), "where2 in detail");
    CHECK(contains(&lay->detail, &lay->d_modified), "modified in detail");
    CHECK(lay->d_kind.top >= lay->d_title.bottom, "kind below title");
    CHECK(lay->d_size.top >= lay->d_kind.bottom, "size below kind");
    CHECK(lay->d_where.top >= lay->d_size.bottom, "where below size");
    CHECK(lay->d_where2.top >= lay->d_where.bottom, "where wraps below");
    CHECK(lay->d_modified.top >= lay->d_where2.bottom,
          "modified below where");

    /* The button row is one baseline. Left group (under the list):
       Rescan then Show in Finder. Right group (under the detail):
       Launch OR Bring to Front (they share a slot, so those two may
       overlap - never shown together), then Quit. */
    CHECK(lay->rescan_btn.top == lay->launch_btn.top, "buttons share a row");
    CHECK(lay->launch_btn.top >= lay->list.bottom, "buttons below panes");
    CHECK(lay->reveal_btn.left > lay->rescan_btn.right,
          "reveal is right of rescan");
    CHECK(disjoint(&lay->rescan_btn, &lay->reveal_btn), "rescan vs reveal");
    CHECK(contains(&lay->list, &lay->rescan_btn) == 0, "rescan below list");
    CHECK(lay->launch_btn.left == lay->front_btn.left,
          "launch shares the front slot");
    CHECK(disjoint(&lay->front_btn, &lay->quit_btn), "front vs quit");
    CHECK(lay->quit_btn.right <= lay->detail.right,
          "quit stays within the detail width");
    CHECK(lay->reveal_btn.right <= lay->list.right,
          "reveal stays under the list");
    CHECK(height(&lay->launch_btn) == kSwButtonHeight, "button height");
    CHECK(height(&lay->rescan_btn) == kSwButtonHeight, "rescan height");

#undef CHECK
}

static void check_formatters(void)
{
    char buf[80];

    sw_size_text(94208L, buf, sizeof buf);            /* 92 KB */
    check(strcmp(buf, "92K") == 0, "size in KB");
    sw_size_text(1153434L, buf, sizeof buf);          /* ~1.1 MB */
    check(strcmp(buf, "1.1M") == 0, "size in MB, one decimal");
    sw_size_text(0L, buf, sizeof buf);
    check(strcmp(buf, "0K") == 0, "zero size");
    sw_size_text(-40L, buf, sizeof buf);
    check(strcmp(buf, "0K") == 0, "negative size clamps");

    sw_kind_text(0x4150504CUL, 0x74747874UL, buf, sizeof buf); /* APPL/ttxt */
    check(strcmp(buf, "APPL / ttxt") == 0, "type and creator");
    sw_kind_text(0x494E4954UL, 0x00010203UL, buf, sizeof buf); /* INIT/junk */
    check(strcmp(buf, "INIT / ....") == 0,
          "unprintable creator becomes dots");

    sw_status_text("applications", 214, 214, -1, 0, buf, sizeof buf);
    check(strcmp(buf, "214 applications") == 0, "settled count");
    sw_status_text("extensions", 139, 139, 3, 0, buf, sizeof buf);
    check(strcmp(buf, "139 extensions - 3 disabled") == 0,
          "disabled count shown");
    sw_status_text("applications", 2, 214, -1, 0, buf, sizeof buf);
    check(strcmp(buf, "2 of 214 applications shown") == 0,
          "search narrows the count");
    sw_status_text("applications", 0, 96, -1, 1, buf, sizeof buf);
    check(strcmp(buf,
                 "Indexing applications - 96 so far, then reading "
                 "versions...") == 0, "sweeping is honest text");
}

int main(void)
{
    Rect body;
    SoftwareLayout lay;

    /* Standard Workshop body: 744x478 content minus the 160 rail, 38
       header, 23 status. */
    body.left = 160;
    body.top = 38;
    body.right = 744;
    body.bottom = 455;
    software_layout_compute(&body, &lay);
    check_common(&body, &lay, "standard");
    check(width(&lay.list) == kSwListWide, "standard: list full width");

    /* Minimum body: 620x430 content, narrow rail. */
    body.left = 128;
    body.top = 38;
    body.right = 620;
    body.bottom = 407;
    software_layout_compute(&body, &lay);
    check_common(&body, &lay, "minimum");
    check(width(&lay.list) == kSwListNarrow, "minimum: list narrows");

    /* An offset origin shifts every rectangle rigidly. */
    {
        SoftwareLayout at_zero, shifted;
        Rect zero, moved;
        const short dx = 40, dy = 60;

        zero.left = 160; zero.top = 38; zero.right = 744; zero.bottom = 455;
        moved.left = (short)(zero.left + dx);
        moved.top = (short)(zero.top + dy);
        moved.right = (short)(zero.right + dx);
        moved.bottom = (short)(zero.bottom + dy);
        software_layout_compute(&zero, &at_zero);
        software_layout_compute(&moved, &shifted);
        check(shifted.list.left - at_zero.list.left == dx
              && shifted.list.top - at_zero.list.top == dy,
              "list shifts rigidly with the origin");
        check(shifted.reveal_btn.right - at_zero.reveal_btn.right == dx,
              "reveal shifts rigidly with the origin");
    }

    check_formatters();

    if (g_failures) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("software_layout_test: all checks passed\n");
    return 0;
}
