/* Native test for the Processes page's pure half. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src processes_layout_test.c \
          ../src/processes_layout.c -o processes_layout_test \
          && ./processes_layout_test

   Geometry at the standard and minimum body sizes plus an offset
   origin, then the formatters - including the unprintable-4CC case,
   because a wild processType must not reach DrawString raw. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "processes_layout.h"

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

static void check_common(const Rect *body, const ProcessesLayout *lay,
                         const char *label)
{
    char what[128];

#define CHECK(cond, text)                                             \
    do {                                                              \
        snprintf(what, sizeof what, "%s: %s", label, text);           \
        check((cond), what);                                          \
    } while (0)

    CHECK(contains(body, &lay->list), "list inside body");
    CHECK(contains(body, &lay->detail), "detail inside body");
    CHECK(disjoint(&lay->list, &lay->detail), "panes do not overlap");
    CHECK(lay->detail.left - lay->list.right == kProcPaneGap,
          "pane gap as specified");

    CHECK(contains(&lay->detail, &lay->title_line), "title in detail");
    CHECK(contains(&lay->detail, &lay->kind_line), "kind in detail");
    CHECK(contains(&lay->detail, &lay->type_line), "type in detail");
    CHECK(contains(&lay->detail, &lay->mem_line), "memory in detail");
    CHECK(contains(&lay->detail, &lay->mem_bar), "bar in detail");
    CHECK(contains(&lay->detail, &lay->cpu_line), "cpu in detail");
    CHECK(contains(&lay->detail, &lay->launched_line),
          "launched in detail");
    CHECK(contains(&lay->detail, &lay->windows_line),
          "windows header in detail");
    CHECK(contains(&lay->detail, &lay->window_rows[0]),
          "first window row in detail");
    CHECK(contains(&lay->detail, &lay->window_rows[kProcDetailWindows - 1]),
          "last window row in detail");
    CHECK(contains(&lay->detail, &lay->menus_line), "menus in detail");
    CHECK(contains(&lay->detail, &lay->front_btn), "front in detail");
    CHECK(contains(&lay->detail, &lay->quit_btn), "quit in detail");
    CHECK(contains(&lay->detail, &lay->group), "group in detail");
    CHECK(contains(&lay->group, &lay->peek_line), "peek line in group");
    CHECK(contains(&lay->group, &lay->capture_btn), "capture btn in group");
    CHECK(lay->capture_btn.top >= lay->peek_line.bottom,
          "capture btn below the status line");
    CHECK(height(&lay->capture_btn) == kProcButtonHeight,
          "capture btn height");

    /* The facts stack, the bar sits under the memory line, the window
       rows stack under their header, and the buttons never collide. */
    CHECK(lay->kind_line.top >= lay->title_line.bottom,
          "kind below title");
    CHECK(lay->type_line.top >= lay->kind_line.bottom,
          "type below kind");
    CHECK(lay->mem_line.top >= lay->type_line.bottom,
          "memory below type");
    CHECK(lay->mem_bar.top >= lay->mem_line.bottom, "bar below memory");
    CHECK(lay->cpu_line.top >= lay->mem_bar.bottom, "cpu below bar");
    CHECK(lay->launched_line.top >= lay->cpu_line.bottom,
          "launched below cpu");
    CHECK(lay->windows_line.top >= lay->launched_line.bottom,
          "windows header below launched");
    CHECK(lay->window_rows[0].top >= lay->windows_line.bottom,
          "window rows below their header");
    CHECK(lay->menus_line.top >= lay->window_rows[kProcDetailWindows - 1].bottom,
          "menus below the window rows");
    CHECK(lay->front_btn.top >= lay->menus_line.bottom,
          "buttons below facts");
    CHECK(disjoint(&lay->front_btn, &lay->quit_btn),
          "buttons do not overlap");
    CHECK(lay->group.top >= lay->front_btn.bottom,
          "group below buttons");

    CHECK(height(&lay->front_btn) == kProcButtonHeight, "button height");
    CHECK(height(&lay->mem_bar) == kProcMemBarHeight, "bar height");
    CHECK(width(&lay->mem_bar) <= kProcMemBarMaxWidth, "bar max width");
    CHECK(height(&lay->group) >= kProcGroupMinHeight,
          "group keeps its height");

#undef CHECK
}

static void check_formatters(void)
{
    char buf[64];

    proc_fourcc_text(0x4150504CUL, buf);          /* 'APPL' */
    check(strcmp(buf, "APPL") == 0, "fourcc prints APPL");
    proc_fourcc_text(0x00010203UL, buf);
    check(strcmp(buf, "....") == 0, "unprintable fourcc becomes dots");

    proc_kind_text(0x4150504CUL, buf, sizeof buf);
    check(strcmp(buf, "application") == 0, "APPL reads application");
    proc_kind_text(0x61707065UL, buf, sizeof buf); /* 'appe' */
    check(strcmp(buf, "background only") == 0, "appe reads background");
    proc_kind_text(0x464E4452UL, buf, sizeof buf); /* 'FNDR' */
    check(strcmp(buf, "the Finder") == 0, "FNDR reads the Finder");
    proc_kind_text(0x494E4954UL, buf, sizeof buf); /* 'INIT' */
    check(strcmp(buf, "INIT") == 0, "unknown kind shows its 4CC");

    proc_mem_text(312, 1024, buf, sizeof buf);
    check(strcmp(buf, "312K used of 1,024K") == 0, "memory text groups");
    proc_mem_text(1847, 2400, buf, sizeof buf);
    check(strcmp(buf, "1,847K used of 2,400K") == 0,
          "memory text groups both");

    check(proc_mem_fill(512, 1024, 200) == 100, "bar fill is half");
    check(proc_mem_fill(2048, 1024, 200) == 200, "bar fill clamps high");
    check(proc_mem_fill(-5, 1024, 200) == 0, "bar fill clamps low");
    check(proc_mem_fill(512, 0, 200) == 0, "zero partition draws empty");

    proc_status_text(7, 12698, buf, sizeof buf);
    check(strcmp(buf, "7 processes - 12.4 MB free") == 0,
          "status line as specified");
    proc_status_text(1, 1024, buf, sizeof buf);
    check(strcmp(buf, "1 process - 1.0 MB free") == 0,
          "status line singular");

    /* processLaunchDate is ticks since boot; the delta is a duration,
       never a date (60 ticks/sec). Coarse below a minute so it does not
       tick every second. */
    proc_uptime_text(60L * 3, buf, sizeof buf);   /* 3 s */
    check(strcmp(buf, "just now") == 0, "under 10s reads just now");
    proc_uptime_text(60L * 30, buf, sizeof buf);  /* 30 s */
    check(strcmp(buf, "less than a minute ago") == 0,
          "under a minute is coarse");
    proc_uptime_text(60L * 60 * 3, buf, sizeof buf); /* 3 min */
    check(strcmp(buf, "3 min ago") == 0, "minutes granularity");
    proc_uptime_text(60L * (3600 * 2 + 60 * 14), buf, sizeof buf);
    check(strcmp(buf, "2 hr 14 min ago") == 0, "hours and minutes");
    proc_uptime_text(60L * 86400 * 3, buf, sizeof buf);
    check(strcmp(buf, "3 days ago") == 0, "days granularity");
    proc_uptime_text(-50, buf, sizeof buf);       /* clock skew guard */
    check(strcmp(buf, "just now") == 0, "negative delta clamps");

    proc_cpu_text(60L * 12, buf, sizeof buf);      /* 12 s */
    check(strcmp(buf, "12 sec") == 0, "cpu seconds");
    proc_cpu_text(60L * (60 * 3 + 20), buf, sizeof buf);
    check(strcmp(buf, "3 min 20 sec") == 0, "cpu minutes and seconds");

    proc_kind_name(kProcKindApp, buf, sizeof buf);
    check(strcmp(buf, "application") == 0, "kind app");
    proc_kind_name(kProcKindBackground, buf, sizeof buf);
    check(strcmp(buf, "background only") == 0, "kind background");
    proc_kind_name(kProcKindFinder, buf, sizeof buf);
    check(strcmp(buf, "the Finder") == 0, "kind finder");

    /* Freshness: live below 3 s (empty), coarse after so it does not
       tick every second. */
    proc_freshness_text(60L, buf, sizeof buf);     /* 1 s */
    check(buf[0] == '\0', "under 3s is live, no marker");
    proc_freshness_text(60L * 20, buf, sizeof buf); /* 20 s */
    check(strcmp(buf, "as of a moment ago") == 0, "seconds are coarse");
    proc_freshness_text(60L * 60 * 4, buf, sizeof buf); /* 4 min */
    check(strcmp(buf, "as of 4 min ago") == 0, "minutes granularity");
}

int main(void)
{
    Rect body;
    ProcessesLayout lay;

    /* The standard Workshop body: 744x478 content minus the 160 rail,
       38 header, 23 status. */
    body.left = 160;
    body.top = 38;
    body.right = 744;
    body.bottom = 455;
    processes_layout_compute(&body, &lay);
    check_common(&body, &lay, "standard");
    check(width(&lay.list) == kProcListWide, "standard: list full width");

    /* The minimum body: 620x430 content, narrow rail. */
    body.left = 128;
    body.top = 38;
    body.right = 620;
    body.bottom = 407;
    processes_layout_compute(&body, &lay);
    check_common(&body, &lay, "minimum");
    check(width(&lay.list) == kProcListNarrow, "minimum: list narrows");

    /* An offset origin must shift every rectangle rigidly. */
    {
        ProcessesLayout at_zero;
        ProcessesLayout shifted;
        Rect zero;
        Rect moved;
        const short dx = 40;
        const short dy = 60;

        zero.left = 160;
        zero.top = 38;
        zero.right = 744;
        zero.bottom = 455;
        moved.left = (short)(zero.left + dx);
        moved.top = (short)(zero.top + dy);
        moved.right = (short)(zero.right + dx);
        moved.bottom = (short)(zero.bottom + dy);
        processes_layout_compute(&zero, &at_zero);
        processes_layout_compute(&moved, &shifted);
        check(shifted.list.left == at_zero.list.left + dx
                  && shifted.detail.top == at_zero.detail.top + dy
                  && shifted.group.bottom == at_zero.group.bottom + dy
                  && shifted.quit_btn.right == at_zero.quit_btn.right + dx,
              "offset origin shifts rigidly");
    }

    check_formatters();

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("processes_layout: all checks passed\n");
    return EXIT_SUCCESS;
}
