/* Native test for the scene's title and rect hygiene
   (src/scene/scene_build.c).
 *
 * WHY THIS FILE EXISTS. Every title in a scene was read out of another
 * process's memory at a literal byte offset, and when a record is not
 * what the walk believed it to be, the same bytes are a 68K address.
 * Sweep A (docs/fidelity-sweep-2026-08-07-a.md) counted the result in
 * every control panel it opened - Memory 21, Monitors 13, Mouse 12,
 * General Controls 7, Date & Time 6, Set Time Zone 5 - plus the
 * application-switcher menu's own title, and eighteen out-of-port rects
 * in Memory alone. The host rendered all of it, because four integers
 * and a byte string are indistinguishable from four honest integers and
 * a real label.
 *
 * The guard is one-way on purpose and this file pins that: a title the
 * guest cannot vouch for is OMITTED, and a rect it cannot vouch for is
 * clamped to a degenerate rect inside its own window rather than shipped
 * as l = 16555, which hit-tests as somewhere.
 *
 * Mutation check, each watched failing 2026-08-07 - see the slice 4
 * report. The mutations were: return 1 unconditionally from
 * now_scene_title_is_publishable; drop the Apple-menu exception; return
 * 1 unconditionally from now_scene_rect_is_sane.
 */

#include <stdio.h>
#include <string.h>

#include "scene.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void check_str(const char *got, const char *want, const char *what)
{
    if (strcmp(got, want) != 0) {
        fprintf(stderr, "FAIL: %s (got \"%s\", want \"%s\")\n", what, got,
                want);
        ++g_failures;
    }
}

/* A scene with one process and one 300x200 window, which is the frame
   every rect below is judged against. */
static int one_window(NowScene *s)
{
    int p;

    now_scene_begin(s, 7, 1000000000.0, "peek", 640, 480, 10000, 0);
    p = now_scene_add_process(s, 0, 33, "Memory", 0, 0, kNowSceneAnchorOk, 0);
    check(p >= 0, "the process is admitted");
    check(now_scene_add_window(s, p, "Memory", 40, 20, 240, 320, 1) == 1,
          "the window is admitted");
    return now_scene_last_window(s);
}

/* --- the predicate, driven directly -------------------------------- */

static void test_predicate(void)
{
    /* Real Mac OS 9 labels, including the half of MacRoman that carries
       accented letters. Rejecting those would be a worse defect than the
       one this guard exists for. */
    check(now_scene_title_is_publishable("Virtual Memory") == 1,
          "plain ASCII is text");
    check(now_scene_title_is_publishable("Set Up Now") == 1,
          "spaces are text");
    check(now_scene_title_is_publishable("R\xe9""glages") == 1,
          "MacRoman's high half is text");
    check(now_scene_title_is_publishable("") == 1, "absent is honest");
    check(now_scene_title_is_publishable(NULL) == 1, "NULL is honest");

    /* The measured shapes. The first is sweep A's application-switcher
       title verbatim; the second is the two-pointer run that arrived as
       Mail's alert message. */
    check(now_scene_title_is_publishable("\x01\x1f@\"\xcf") == 0,
          "the app-switcher icon title is not text");
    check(now_scene_title_is_publishable(
              "\x1d\xb5\x13\xe5\x1d\xb5\x17\xc4") == 0,
          "two 68K addresses are not text");
    check(now_scene_title_is_publishable("OK\x07") == 0,
          "one control byte spoils a title that starts plausibly");
    check(now_scene_title_is_publishable("\x7f") == 0, "DEL is not text");

    /* The one documented exception, and downstream depends on it:
       now_scene_fill_blank_system_apple finds the Apple menu by this
       exact byte. */
    check(now_scene_title_is_publishable("\x14") == 1,
          "the Apple menu's 0x14 survives");
    check(now_scene_title_is_publishable("\x14\x14") == 0,
          "and only as a title of exactly one byte");
}

/* --- the predicate, applied by the assembly functions --------------- */

static void test_titles_are_omitted(void)
{
    NowScene s;
    int w;
    const char *garbage = "\x1d\xb5\x13\xe5";

    w = one_window(&s);
    check(now_scene_add_control(&s, w, garbage, 10, 10, 30, 100, 1, 1,
                                0, 0, 1) == 1,
          "a control with an unreadable title is still ADMITTED");
    check_str(s.controls[0].title, "",
              "...and publishes no title at all");

    check(now_scene_add_control(&s, w, "Virtual Memory", 40, 10, 60, 100,
                                1, 1, 0, 0, 1) == 1,
          "a real title is admitted");
    check_str(s.controls[1].title, "Virtual Memory",
              "...and survives byte for byte");
}

static void test_menu_titles_are_omitted(void)
{
    NowScene s;
    int row;

    now_scene_begin(&s, 7, 1000000000.0, "peek", 640, 480, 10000, 0);
    check(now_scene_add_process(&s, 0, 33, "Finder", 0, 0,
                                kNowSceneAnchorOk, 0) >= 0,
          "the process is admitted");
    check(now_scene_open_menubar(&s, 0) == 1, "the menu bar opens");

    row = now_scene_add_menu(&s, "\x01\x1f@\"\xcf", 1000, 500);
    check(row >= 0, "the application-switcher menu is still a ROW");
    check_str(s.menus[row].title, "",
              "...with no title, rather than five bytes of address");

    row = now_scene_add_menu(&s, "\x14", 1, 10);
    check(row >= 0, "the Apple menu is a row");
    check_str(s.menus[row].title, "\x14",
              "...and keeps the byte that identifies it");

    row = now_scene_add_menu(&s, "File", 2, 40);
    check(row >= 0, "File is a row");
    check_str(s.menus[row].title, "File", "...and keeps its name");
}

/* --- rects ---------------------------------------------------------- */

static void test_rect_predicate(void)
{
    check(now_scene_rect_is_sane(10, 10, 30, 100) == 1, "an ordinary rect");
    check(now_scene_rect_is_sane(0, 0, 0, 0) == 1,
          "a zero rect is degenerate, not insane");
    check(now_scene_rect_is_sane(-40, -900, 10, 20) == 1,
          "a control scrolled out of view is still sane");
    /* Sweep A's own numbers. */
    check(now_scene_rect_is_sane(10, 16555, 30, 16600) == 0,
          "16555 is the top half of an address, not a position");
    check(now_scene_rect_is_sane(10, 16584, 30, 16600) == 0,
          "so is 16584");
    check(now_scene_rect_is_sane(30, 10, 10, 100) == 0,
          "an unordered rect is a misread");
}

static void test_insane_rects_are_clamped(void)
{
    NowScene s;
    int w;

    w = one_window(&s);
    check(now_scene_add_control(&s, w, "Off", 10, 16555, 30, 16600, 1, 1,
                                0, 0, 1) == 1,
          "a control with an impossible rect is still admitted");
    check(s.controls[0].rect.l == 300 && s.controls[0].rect.r == 300,
          "...clamped to the window's own width");
    check(s.controls[0].rect.t == 10 && s.controls[0].rect.b == 30,
          "...on the axis that was insane only");
    check(now_scene_rect_is_sane(s.controls[0].rect.t, s.controls[0].rect.l,
                                 s.controls[0].rect.b, s.controls[0].rect.r)
              == 1,
          "...and what ships is sane");

    check(now_scene_add_control(&s, w, "On", -40, 8, -10, 90, 1, 1,
                                0, 0, 1) == 1,
          "a scrolled-away control is admitted");
    check(s.controls[1].rect.t == -40 && s.controls[1].rect.b == -10,
          "...and is NOT moved: the guard is a lie detector, not a layout "
          "rule");
}

static void test_dialog_item_rects_are_clamped(void)
{
    NowScene s;
    int w;

    w = one_window(&s);
    check(now_scene_add_dialog_item(&s, w, 1, kNowSceneSemanticPushButton,
                                    "Yes", 16504, 10, 16530, 60, 1, 1) == 1,
          "a dialog item with an impossible rect is admitted");
    check(s.dialog_items[0].rect.t == 200 && s.dialog_items[0].rect.b == 200,
          "...clamped to the window's own height");
    check_str(s.dialog_items[0].title, "Yes", "...keeping its real title");
}

int main(void)
{
    test_predicate();
    test_titles_are_omitted();
    test_menu_titles_are_omitted();
    test_rect_predicate();
    test_insane_rects_are_clamped();
    test_dialog_item_rects_are_clamped();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
