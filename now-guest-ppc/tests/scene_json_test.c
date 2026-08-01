/* Native test for the IR v1 encoder (src/scene/scene_json.c).
 *
 * Two things are being pinned here and they pull in opposite directions.
 *
 * ABSENCE, and it moved on 2026-07-31 when the ported walk was wired in.
 * `display`, `desktopItems`, `items` (the window kind) and `meta.bytes`
 * must still not appear AT ALL: this producer does not report them, and
 * an empty array would assert "this window has no controls" where
 * absence says "this producer does not report controls".
 *
 * `menubar`, `menus`, `controls`, `text` and `kind` moved from the never
 * list to the CONDITIONAL one, which is a harder thing to test and the
 * reason `test_conditional_planes` exists.
 *
 * `ref` moved the same way on 2026-08-01, and it is the entry on the
 * never list whose removal had to be deliberate: it was there because the
 * producer could not mint one, and the producer can now. What did NOT
 * move is the shape of its absence. `ref` is emitted only for an element
 * the reference layer actually named; the empty string must never reach
 * the wire, because the host adapter reads a present-but-empty `ref` as
 * "this producer has no reference layer" - a different claim from "this
 * element was not minted", and false. `role` and `checked` stay on the
 * never list, unmoved: the walk still does not read a defProc. Each must be absent on a row
 * whose walk did not run, present on a row whose did, and - the case
 * that carries the whole design - present-and-EMPTY on a row that was
 * walked and legitimately has none. A test that only checked "menus can
 * appear" would pass while the encoder emitted `"controls":[]` on every
 * window in the scene.
 *
 * SIZE. The scene is sized here against the 4096-byte control-frame cap,
 * on OUR numbers rather than upstream's, because that number is what
 * decides whether a scene can ever be a control message
 * (docs/scene-producer.md, docs/streaming-a-scene.md).
 *
 * Mutation check, each watched failing 2026-07-31 - see the report in
 * docs/scene-producer.md.
 */

#include <stdio.h>
#include <stdlib.h>
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

static void check_absent(const char *json, const char *key)
{
    if (strstr(json, key) != NULL) {
        fprintf(stderr, "FAIL: %s appears in the scene; an unproduced plane "
                "is an ABSENT key, not an empty one\n", key);
        ++g_failures;
    }
}

static void check_present(const char *json, const char *fragment)
{
    if (strstr(json, fragment) == NULL) {
        fprintf(stderr, "FAIL: missing %s\n", fragment);
        ++g_failures;
    }
}

/* Brackets balance outside strings, and no string is left open. Not a
   parser - just enough that a truncation or a stray quote cannot pass as
   a scene. */
static int well_formed(const char *json)
{
    int depth = 0;
    int in_str = 0;
    const char *p;

    for (p = json; *p != '\0'; ++p) {
        if (in_str) {
            if (*p == '\\' && p[1] != '\0') {
                ++p;
            } else if (*p == '"') {
                in_str = 0;
            }
            continue;
        }
        if (*p == '"') {
            in_str = 1;
        } else if (*p == '{' || *p == '[') {
            ++depth;
        } else if (*p == '}' || *p == ']') {
            if (--depth < 0) {
                return 0;
            }
        }
    }
    return depth == 0 && !in_str;
}

/* A small, realistic desktop: the Finder with two windows, a front app
   with one, one process whose anchor is ambiguous, one that is simply
   quiet. */
static void build_small(NowScene *s)
{
    int finder, text, ghost, quiet;

    now_scene_begin(s, 3, 1000000000.0, "peek", 640, 480, 20000, 3600);
    finder = now_scene_add_process(s, 0, 29884417UL, "Finder", 0x4D414353UL,
                                   0, kNowSceneAnchorOk, 19990);
    text = now_scene_add_process(s, 0, 32636930UL, "SimpleText",
                                 0x74747874UL, 1, kNowSceneAnchorOk, 19995);
    ghost = now_scene_add_process(s, 0, 32178179UL, "tbt-worker", 0, 0,
                                  kNowSceneAnchorAmbiguous, 0);
    quiet = now_scene_add_process(s, 0, 31588353UL, "Folder Actions",
                                  0x73737276UL, 0, kNowSceneAnchorNoWindows,
                                  19000);
    (void)quiet;
    now_scene_add_window(s, finder, "Macintosh HD", 20, 4, 300, 420, 1);
    now_scene_add_window(s, finder, "Lab", 60, 40, 340, 460, 1);
    now_scene_add_window(s, text, "untitled", 20, 4, 581, 619, 1);
    now_scene_add_window(s, ghost, "should not appear", 0, 0, 10, 10, 1);
}

static void test_produced_fields(void)
{
    NowScene s;
    char out[8192];

    build_small(&s);
    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the small scene encodes");
    check(well_formed(out), "and is well formed");

    check_present(out, "\"version\":1");
    check_present(out, "\"seq\":3");
    check_present(out, "\"capturedAt\":1000000000.0");
    check_present(out, "\"source\":\"peek\"");
    check_present(out, "\"screen\":{\"w\":640,\"h\":480}");
    check_present(out, "\"psn\":\"0.29884417\"");
    check_present(out, "\"signature\":\"MACS\"");
    check_present(out, "\"id\":\"0.32636930/untitled#0\"");
    check_present(out, "\"rect\":{\"l\":4,\"t\":20,\"r\":619,\"b\":581}");
    check_present(out, "\"front\":true");
    check_present(out, "\"visible\":true");
}

static void test_unproduced_planes_are_absent(void)
{
    NowScene s;
    char out[8192];

    build_small(&s);
    (void)now_scene_encode(&s, out, sizeof out, NULL);

    /* Planes this producer does not report AT ALL, still. */
    check_absent(out, "display");
    check_absent(out, "desktopItems");
    check_absent(out, "island");
    /* The conditional planes, on a scene whose walk did not run: absent,
       not empty. `build_small` adds windows without walking any of
       them, which is exactly the state a process reached through
       peek_read.c alone is in. */
    check_absent(out, "controls");
    check_absent(out, "menubar");
    check_absent(out, "menus");
    check_absent(out, "\"text\"");
    check_absent(out, "\"kind\"");
    check_absent(out, "\"items\"");
    /* meta.bytes is the encoded size, and the encode is what is
       happening; latencyMs is absent until something measures it. */
    check_absent(out, "\"bytes\"");
    check_absent(out, "latencyMs");
    /* `ref` on a scene nothing minted for: absent everywhere, including
       as an empty string. `build_small` walks nothing, so no element in
       it was ever named. */
    check_absent(out, "\"ref\"");
    /* And the two the walk still cannot say anything about at all. */
    check_absent(out, "role");
    check_absent(out, "checked");
    /* But meta.errors is EMITTED even when empty: it is a list of things
       that went wrong during a walk that did happen, not a plane this
       producer declines to report. */
    check_present(out, "\"errors\":[");
}

/* The three states of a conditional plane, in one scene, so the encoder
   cannot satisfy any of them by emitting the same thing everywhere.
   Absent / present-and-empty / present-and-populated are three different
   claims about three windows of the same machine. */
static void test_conditional_planes(void)
{
    NowScene s;
    char out[16384];
    int p;
    const char *w0;
    const char *w1;
    const char *w2;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 9, "SimpleText", 0x74747874UL, 1,
                              kNowSceneAnchorOk, 0);

    /* Window 0: walked, and it has controls. */
    (void)now_scene_add_window(&s, p, "Save As", 40, 60, 200, 400, 1);
    now_scene_set_window_kind(&s, 0, 2);
    (void)now_scene_add_control(&s, 0, "OK", 50, 80, 70, 150, 1, 1, 1, 0, 1);
    now_scene_set_window_text(&s, 0, "Untitled", 1, 0);

    /* Window 1: walked, and it genuinely has none. */
    (void)now_scene_add_window(&s, p, "Palette", 10, 10, 60, 120, 1);
    now_scene_set_window_kind(&s, 1, 8);
    check(now_scene_open_controls(&s, 1) == 1, "the empty plane opens");

    /* Window 2: never walked. */
    (void)now_scene_add_window(&s, p, "Untouched", 0, 0, 50, 50, 1);

    now_scene_open_menubar(&s, p);
    {
        int m = now_scene_add_menu(&s, "File", 129, 0);

        check(m == 0, "the menu is added");
        (void)now_scene_add_menu_item(&s, m, "New", 1, 0, 1, 0, 'N');
        (void)now_scene_add_menu_item(&s, m, "-", 2, 1, 0, 0, '\0');
    }

    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the walked scene encodes");
    check(well_formed(out), "and is well formed");

    check_present(out, "\"menubar\":{\"app\":\"SimpleText\"");
    check_present(out, "\"title\":\"File\",\"id\":129,\"left\":0");
    check_present(out, "\"title\":\"New\",\"index\":1,\"separator\":false,"
                  "\"enabled\":true,\"mark\":false,\"cmd\":\"N\"");
    /* An item with no command key carries no `cmd` at all - the key says
       there is a shortcut, and an empty string would say there is one
       spelled "". */
    check_present(out, "\"title\":\"-\",\"index\":2,\"separator\":true");
    check_absent(out, "\"cmd\":\"\"");
    /* `apple` is not emitted: nothing this walk reads says which menu is
       the Apple menu, so the key stays absent rather than guessing. */
    check_absent(out, "apple");

    w0 = strstr(out, "\"title\":\"Save As\"");
    w1 = strstr(out, "\"title\":\"Palette\"");
    w2 = strstr(out, "\"title\":\"Untouched\"");
    check(w0 != NULL && w1 != NULL && w2 != NULL && w0 < w1 && w1 < w2,
          "the three windows encode in order");
    if (w0 == NULL || w1 == NULL || w2 == NULL) {
        return;
    }
    /* Populated. The rect is the CONTROL's own, already global. */
    check(strstr(w0, "\"kind\":2") != NULL && strstr(w0, "\"kind\":2") < w1,
          "the walked dialog carries its kind");
    check(strstr(w0, "\"controls\":[{\"title\":\"OK\",\"rect\":{\"l\":80,"
                 "\"t\":50,\"r\":150,\"b\":70}") != NULL,
          "and its controls, in global coordinates");
    check(strstr(w0, "\"text\":{\"content\":\"Untitled\",\"active\":true}")
          != NULL, "and its dialog text");

    /* Empty - and this is the assertion the design turns on. */
    check(strstr(w1, "\"controls\":[]") != NULL
          && strstr(w1, "\"controls\":[]") < w2,
          "a window that WAS walked and has none says so with an empty "
          "array, which is a claim about the machine");
    check(strstr(w1, "\"text\"") == NULL || strstr(w1, "\"text\"") > w2,
          "and carries no text key, because it has no TextEdit record");

    /* Absent. Same scene, same encoder, no keys. */
    check(strstr(w2, "controls") == NULL, "an unwalked window has no "
          "controls key at all - not an empty one");
    check(strstr(w2, "\"kind\"") == NULL, "and no kind");
    check(strstr(w2, "\"text\"") == NULL, "and no text");
}

/* Every retraction reaches meta.errors. A sub-plane that vanished with
   nothing said would be indistinguishable from one that was never
   walked, which is the confusion the whole present-vs-absent split
   exists to prevent. */
static void test_retractions_are_reported(void)
{
    NowScene s;
    char out[16384];
    int p;
    int i;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 1, "Busy", 0, 1, kNowSceneAnchorOk, 0);
    (void)now_scene_add_window(&s, p, "Doc", 0, 0, 10, 10, 1);
    (void)now_scene_add_control(&s, 0, "OK", 0, 0, 5, 5, 1, 1, 0, 0, 1);
    now_scene_retract_controls(&s, 0);
    check(s.control_count == 0, "the pool is returned");

    now_scene_open_menubar(&s, p);
    (void)now_scene_add_menu(&s, "File", 129, 0);
    (void)now_scene_add_menu_item(&s, 0, "New", 1, 0, 1, 0, 'N');
    now_scene_retract_menu_items(&s, 0);

    for (i = 0; i < kNowSceneMaxTexts + 1; ++i) {
        char title[8];

        snprintf(title, sizeof title, "D%d", i);
        (void)now_scene_add_window(&s, p, title, 0, 0, 10, 10, 1);
        now_scene_set_window_text(&s, now_scene_last_window(&s), "x", 1, 0);
    }

    (void)now_scene_encode(&s, out, sizeof out, NULL);
    check_present(out, "controls omitted");
    check_present(out, "menu items omitted");
    check_present(out, "window text omitted");
    /* The retracted keys really are gone, not merely flagged. */
    check_absent(out, "\"controls\":");
    check_absent(out, "\"items\":");
    check(well_formed(out), "a scene full of retractions is still valid JSON");

    /* A menubar that was opened and then dropped says so too, and leaves
       no menubar key behind. */
    now_scene_retract_menubar(&s);
    (void)now_scene_encode(&s, out, sizeof out, NULL);
    check_absent(out, "menubar\":");
    check_present(out, "menubar omitted");
}

static void test_verdicts_reach_the_wire(void)
{
    NowScene s;
    char out[8192];

    build_small(&s);
    (void)now_scene_encode(&s, out, sizeof out, NULL);

    check_present(out, "\"error\":\"ax_oracle_ambiguous\"");
    check_present(out, "\"tbt-worker: ax_oracle_ambiguous\"");
    /* The ambiguous process is CARRIED, with no windows attributed to
       it - the whole point of the verdict. */
    check_present(out, "\"name\":\"tbt-worker\"");
    check_absent(out, "should not appear");
    /* A clean process carries no `error` key at all, and a quiet one is
       not an error either. */
    check_absent(out, "\"error\":null");
    check_absent(out, "Folder Actions: ");

    /* Stale: old but clean, reported beside its data. */
    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 20000, 600);
    (void)now_scene_add_process(&s, 0, 5, "Sleepy", 0, 0, kNowSceneAnchorOk,
                                1000);
    (void)now_scene_add_window(&s, 0, "Doc", 20, 4, 100, 200, 1);
    (void)now_scene_encode(&s, out, sizeof out, NULL);
    check_present(out, "\"error\":\"ax_oracle_stale\"");
    check_present(out, "\"title\":\"Doc\"");
}

static void test_truncation_shows_up_in_meta(void)
{
    NowScene s;
    char out[16384];
    int i;
    int p;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 1, "Busy", 0, 1, kNowSceneAnchorOk, 0);
    for (i = 0; i < kNowSceneMaxWindows + 3; ++i) {
        (void)now_scene_add_window(&s, p, "W", 0, 0, 10, 10, 1);
    }
    (void)now_scene_encode(&s, out, sizeof out, NULL);
    check_present(out, "windows truncated");
    check(well_formed(out), "a truncated walk still encodes as valid JSON");
}

/* Fails closed. A scene that does not fit produces NOTHING - not a
   prefix, not a half object - because half a JSON scene does not even
   parse, and a consumer that got one would be reading a machine state
   that never existed. */
static void test_overflow_fails_closed(void)
{
    NowScene s;
    char out[8192];
    long needed = 0;
    long exact;

    build_small(&s);
    exact = now_scene_encoded_size(&s);
    check(exact > 0, "sizing without encoding works");

    memset(out, 'X', sizeof out);
    check(now_scene_encode(&s, out, exact - 1, &needed)
          == kNowSceneEncodeOverflow, "one byte short overflows");
    check(out[0] == '\0', "and leaves nothing behind");
    check(needed == exact, "reporting exactly what it would have taken");

    memset(out, 'X', sizeof out);
    check(now_scene_encode(&s, out, exact, &needed) == kNowSceneEncodeOk,
          "exactly enough is enough");
    check((long)strlen(out) == exact - 1, "and the size accounting is exact");
    check(well_formed(out), "the tight encode is still well formed");
}

/* Escaping: a title is a person's text, and the guest speaks MacRoman.
   Quotes must not break the object and high bytes must not leave as raw
   bytes, which are invalid JSON and invalid UTF-8 both. */
static void test_escaping(void)
{
    NowScene s;
    char out[8192];
    int p;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 1, "Finder", 0x4D414353UL, 1,
                              kNowSceneAnchorOk, 0);
    (void)now_scene_add_window(&s, p, "He said \"hi\"\xC4", 0, 0, 10, 10, 1);
    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "a quoted title encodes");
    check(well_formed(out), "and does not break the object");
    check_present(out, "He said \\\"hi\\\"");
    check_present(out, "\\u0192");    /* MacRoman 0xC4 is the florin sign */
}

/* The number the serving decision rests on. A scene of an ordinary
   desktop does NOT fit a 4096-byte control frame, so a scene is a
   transfer - stated here in our own encoder's bytes rather than borrowed
   from upstream's fixture corpus. */
static void build_realistic(NowScene *s, int walked)
{
    int i;

    now_scene_begin(s, 1, 1000000000.0, "peek", 832, 624, 20000, 3600);
    for (i = 0; i < 24; ++i) {
        char name[kNowSceneNameMax];
        int p;

        snprintf(name, sizeof name, "Application %d", i);
        p = now_scene_add_process(s, 0, (unsigned long)(29884417 + i * 1024),
                                  name, 0x4D414353UL, i == 0,
                                  kNowSceneAnchorOk, 19990);
        (void)now_scene_add_window(s, p, "Untitled document", 20, 4, 300,
                                   420, 1);
        if (i % 3 == 0) {
            (void)now_scene_add_window(s, p, "Another window", 40, 40, 320,
                                       440, 1);
        }
    }
    if (!walked) {
        return;
    }
    /* What the walk adds to the same desktop: every window's kind, a
       scroll bar and a grow box on each - two controls is a modest
       document window, not a dialog - and the front app's menu bar. */
    for (i = 0; i < s->window_count; ++i) {
        now_scene_set_window_kind(s, i, 8);
        (void)now_scene_add_control(s, i, "", 20, 400, 300, 416, 1, 1,
                                    0, 0, 100);
        (void)now_scene_add_control(s, i, "", 284, 400, 300, 416, 1, 1,
                                    0, 0, 0);
    }
    now_scene_open_menubar(s, 0);
    for (i = 0; i < 6; ++i) {
        static const char *titles[6] = { "File", "Edit", "View", "Special",
                                         "Help", "Window" };
        int m = now_scene_add_menu(s, titles[i], (short)(129 + i),
                                   (short)(i * 44));
        int j;

        for (j = 0; j < 8; ++j) {
            char item[24];

            snprintf(item, sizeof item, "Command %d", j);
            (void)now_scene_add_menu_item(s, m, item, (short)(j + 1), 0, 1,
                                          0, (char)('A' + j));
        }
    }
}

static void test_size_against_the_control_cap(void)
{
    NowScene s;
    long small, realistic, walked;
    long ceiling;

    build_small(&s);
    small = now_scene_encoded_size(&s);
    printf("  scene size: 4 processes / 3 windows = %ld bytes\n", small);

    build_realistic(&s, 0);
    realistic = now_scene_encoded_size(&s);
    printf("  scene size: %d processes / %d windows = %ld bytes\n",
           (int)s.proc_count, (int)s.window_count, realistic);
    check(realistic > 4096,
          "a realistic desktop exceeds the 4096-byte control cap, so a "
          "scene is a transfer and not a control message");
    check(small < realistic, "and it grows with the machine");

    /* The same desktop with the walked planes on it. This is the number
       that decides nothing about the control frame (already answered no)
       and everything about what a transfer costs on a 33 MHz machine. */
    build_realistic(&s, 1);
    walked = now_scene_encoded_size(&s);
    printf("  scene size: the same desktop, walked (%d controls, %d menu "
           "items) = %ld bytes\n", (int)s.control_count,
           (int)s.menu_item_count, walked);
    check(walked > realistic, "the walked planes cost real bytes");

    /* THE CEILING, computed rather than asserted from a run. Every pool
       full, every string at its cap: this is the largest scene this
       producer can emit, and it is what a serving layer must be able to
       carry. It is a bound on the struct, so it cannot be exceeded by a
       busier machine - only reported truncated. */
    now_scene_begin(&s, 999999, 1000000000.0, "peek", 832, 624, 0, 0);
    {
        int i;

        for (i = 0; i < kNowSceneMaxProcs; ++i) {
            char name[kNowSceneNameMax];

            memset(name, 'M', sizeof name);
            name[sizeof name - 1] = '\0';
            (void)now_scene_add_process(&s, 0,
                                        (unsigned long)(29884417 + i * 1024),
                                        name, 0x4D414353UL, i == 0,
                                        kNowSceneAnchorOk, 0);
        }
        for (i = 0; i < kNowSceneMaxWindows; ++i) {
            char title[kNowSceneTitleMax];

            memset(title, 'W', sizeof title);
            title[sizeof title - 1] = '\0';
            (void)now_scene_add_window(&s, i % kNowSceneMaxProcs, title,
                                       0, 0, 999, 999, 1);
        }
        for (i = 0; i < kNowSceneMaxControls; ++i) {
            char title[kNowSceneCtlTitleMax];

            memset(title, 'C', sizeof title);
            title[sizeof title - 1] = '\0';
            (void)now_scene_add_control(&s, i % kNowSceneMaxWindows, title,
                                        999, 999, 999, 999, 1, 1, 0, 0, 0);
        }
        for (i = 0; i < kNowSceneMaxTexts; ++i) {
            char text[kNowSceneTextMax];

            memset(text, 'T', sizeof text);
            text[sizeof text - 1] = '\0';
            now_scene_set_window_text(&s, i, text, 1, 1);
        }
        now_scene_open_menubar(&s, 0);
        for (i = 0; i < kNowSceneMaxMenus; ++i) {
            char title[kNowSceneMenuTitleMax];
            int m;
            int j;

            memset(title, 'N', sizeof title);
            title[sizeof title - 1] = '\0';
            m = now_scene_add_menu(&s, title, 129, 0);
            for (j = 0; j < kNowSceneMaxMenuItems; ++j) {
                char item[kNowSceneItemTitleMax];

                memset(item, 'I', sizeof item);
                item[sizeof item - 1] = '\0';
                if (!now_scene_add_menu_item(&s, m, item, (short)(j + 1),
                                             0, 1, 1, 'X')) {
                    break;
                }
            }
        }
    }
    /* Every row also NAMED. A reference is 48-49 bytes of JSON per
       element and there are up to 160 of them, so a ceiling measured
       without the reference plane understates by about a fifth of
       itself - and this number is the one a serving layer sizes its
       buffer from. Filling it here is what keeps the two honest. */
    {
        int i;

        for (i = 0; i < s.window_count; ++i) {
            now_scene_set_window_ref(&s, i,
                "now-window-ffffffff-ffff-ffff-ffff-ffffffffffff");
        }
        for (i = 0; i < s.window_count; ++i) {
            int j;

            for (j = 0; j < (int)s.windows[i].control_count; ++j) {
                now_scene_set_control_ref(&s, i, j,
                    "now-element-ffffffff-ffff-ffff-ffff-ffffffffffff");
            }
        }
    }
    ceiling = now_scene_encoded_size(&s);
    printf("  scene ceiling: every pool full and every row named = %ld "
           "bytes\n", ceiling);
    /* Note the controls are only *nearly* at the cap: the pool fills
       round-robin across windows, so one window's block stops being the
       tail and assembly refuses the misfile. That is the invariant
       working, and it means this number is an over- rather than
       under-estimate of a real ceiling. */
    check(ceiling < 65536,
          "the largest scene this producer can emit fits in 64 KB, which "
          "is what a serving layer must be able to carry - and it is a "
          "bound on the STRUCT, so a busier machine truncates rather "
          "than exceeding it");
    check(ceiling > walked, "and it is above what a real desktop measured");
}

/* The reference plane, which is what makes a rendered scene actable.
   Three states again, and the middle one is the whole point: a control
   the walk named, a control it could not, and a window carrying its own
   reference. An encoder that emitted `"ref":""` for the second would
   satisfy any test that only looked for the key. */
static void test_reference_plane(void)
{
    NowScene s;
    char out[16384];
    int p;
    const char *w0;
    const char *w1;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 9, "SimpleText", 0x74747874UL, 1,
                              kNowSceneAnchorOk, 0);

    /* Window 0: named, and one of its two controls is named. */
    (void)now_scene_add_window(&s, p, "Save As", 40, 60, 200, 400, 1);
    now_scene_set_window_ref(&s, 0,
        "now-window-0123456789ab-cdef-0123-4567-89abcdef0123");
    (void)now_scene_add_control(&s, 0, "OK", 50, 80, 70, 150, 1, 1, 1, 0, 1);
    (void)now_scene_add_control(&s, 0, "Cancel", 50, 200, 70, 270, 1, 1, 0,
                                0, 1);
    now_scene_set_control_ref(&s, 0, 0,
        "now-element-00000000-1111-2222-3333-444444444444");

    /* Window 1: walked, and NOT named - the registry had nothing left, or
       it sits past the resolver's reach. */
    (void)now_scene_add_window(&s, p, "Palette", 10, 10, 60, 120, 1);
    (void)now_scene_add_control(&s, 1, "Zoom", 20, 20, 40, 60, 1, 1, 0, 0, 1);

    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the referenced scene encodes");
    check(well_formed(out), "and is well formed");
    check_absent(out, "\"ref\":\"\"");

    check_present(out,
        "\"ref\":\"now-element-00000000-1111-2222-3333-444444444444\"");
    check_present(out,
        "\"ref\":\"now-window-0123456789ab-cdef-0123-4567-89abcdef0123\"");

    w0 = strstr(out, "\"title\":\"Save As\"");
    w1 = strstr(out, "\"title\":\"Palette\"");
    check(w0 != NULL && w1 != NULL && w0 < w1, "both windows encode");
    if (w0 == NULL || w1 == NULL) {
        return;
    }
    /* The unnamed control is emitted in full and carries no `ref` - it is
       drawn, and it is not actable, and the scene says both. */
    check(strstr(w0, "\"title\":\"Cancel\"") != NULL,
          "the unnamed control is still reported");
    check(strstr(w1, "\"ref\"") == NULL,
          "and a window the reference layer could not name carries no ref "
          "key - not an empty one");

    /* A reference longer than one can be is refused, not truncated: a
       shortened token is well formed to every shape check on both sides
       and resolves to nothing. */
    now_scene_set_control_ref(&s, 1, 0,
        "now-element-00000000-1111-2222-3333-444444444444"
        "-and-then-some-more-that-does-not-fit-at-all");
    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the scene still encodes");
    check(strstr(out, "\"ref\":\"now-element-00000000-1111-2222-3333-"
                 "444444444444-") == NULL,
          "an over-long reference is dropped rather than clipped");
}

int main(void)
{
    test_produced_fields();
    test_unproduced_planes_are_absent();
    test_conditional_planes();
    test_reference_plane();
    test_retractions_are_reported();
    test_verdicts_reach_the_wire();
    test_truncation_shows_up_in_meta();
    test_overflow_fails_closed();
    test_escaping();
    test_size_against_the_control_cap();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("scene_json: ok\n");
    return 0;
}
