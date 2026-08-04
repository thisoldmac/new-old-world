/* Native test for the scene IR encoder (src/scene/scene_json.c).
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

    check_present(out, "\"version\":2");
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

static void test_coverage_and_incarnation_reach_the_wire(void)
{
    NowScene s;
    char out[8192];
    int p;

    now_scene_begin(&s, 41, 0.0, "peek", 640, 480, 0, 0);
    now_scene_set_processes_coverage(&s, kNowSceneCoverageComplete);
    p = now_scene_add_process(&s, 0, 9, "Finder", 0x4D414353UL, 1,
                              kNowSceneAnchorOk, 0);
    now_scene_set_process_incarnation(&s, p, 0x89abcdefUL);
    now_scene_set_windows_coverage(&s, p, kNowSceneCoverageComplete);
    (void)now_scene_add_window(&s, p, "Macintosh HD", 20, 0, 300, 400, 1);
    now_scene_set_window_addr(&s, 0, 0x12345678UL);
    (void)now_scene_open_menubar(&s, p);
    now_scene_retract_menubar(&s);

    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the covered scene encodes");
    check_present(out, "\"incarnation\":\"process-89abcdef\"");
    check_present(out,
                  "\"incarnation\":\"process-89abcdef/window-12345678\"");
    check_present(out,
                  "\"coverage\":[{\"scope\":\"processes\","
                  "\"status\":\"complete\"}");
    check_present(out,
                  "\"scope\":\"windows\",\"owner\":"
                  "\"process-89abcdef\",\"status\":\"complete\"");
    check_present(out,
                  "\"scope\":\"menubar\",\"owner\":"
                  "\"process-89abcdef\",\"status\":\"retracted\"");
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
       peek_read.c alone is in.

       TWO KEYS LEFT THIS LIST ON 2026-08-02, and the reason is worth
       keeping: `controls` and `items` are REQUIRED by the IR this
       producer names in its own envelope, and MirrorKit - the type that
       IR belongs to - refuses a document without them. The absent-key
       rule is right where this producer defines the shape; it is not
       ours to apply to somebody else's contract, where an omission does
       not read as "none" but as unparseable. They are now emitted
       empty, and what the absence used to convey lives in meta's
       truncation note. See SceneIRDecodeTests. */
    check_absent(out, "\"menubar\":");
    check_absent(out, "\"menus\":");
    check_absent(out, "\"text\"");
    check_absent(out, "\"kind\"");
    /* meta.bytes is the encoded size, and the encode is what is
       happening; latencyMs is absent until something measures it. */
    check_absent(out, "\"bytes\"");
    check_absent(out, "latencyMs");
    /* `ref` on a scene nothing minted for: absent everywhere, including
       as an empty string. `build_small` walks nothing, so no element in
       it was ever named. */
    check_absent(out, "\"ref\"");
    /* `checked` the walk still cannot say anything about at all - it
       reads a ControlRecord and not its defProc - and MirrorKit tolerates
       its absence for exactly that reason. `role` LEFT this list: the IR
       requires it, and a live range versus none is a distinction this
       reader can make honestly. */
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
    /* `apple` now sits between the title and the id: the IR requires it
       on every menu, and identifies the Apple menu by that flag rather
       than by a title glyph. */
    check_present(out, "\"title\":\"File\",\"apple\":false,"
                  "\"id\":129,\"left\":0");
    check_present(out, "\"title\":\"New\",\"index\":1,\"separator\":false,"
                  "\"enabled\":true,\"mark\":false,\"cmd\":\"N\"");
    /* An item with no shortcut carries `cmd` as the EMPTY STRING, which
       is the IR's own spelling for "none". This asserted the opposite
       until 2026-08-02 - the key present meaning there is a shortcut -
       which is the better rule for a shape this producer owns and the
       wrong one for a contract it merely implements: MirrorKit refuses a
       document missing the key. */
    check_present(out, "\"title\":\"-\",\"index\":2,\"separator\":true");
    check_present(out, "\"cmd\":\"\"");
    /* And the Apple menu is flagged, with an EMPTY title, because that
       is how the IR names it. */
    check_present(out, "\"apple\":false");

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
    check(strstr(w0, "\"controls\":[{\"role\":") != NULL
          && strstr(w0, "\"title\":\"OK\"") != NULL
          && strstr(w0, "\"rect\":{\"l\":80,\"t\":50,\"r\":150,\"b\":70}")
             != NULL,
          "and its controls, in global coordinates, each with the role the "
          "IR requires - control, or scrollbar when it carries a range");
    check(strstr(w0, "\"text\":{\"content\":\"Untitled\",\"active\":true}")
          != NULL, "and its dialog text");

    /* Empty - and this is the assertion the design turns on. */
    check(strstr(w1, "\"controls\":[]") != NULL
          && strstr(w1, "\"controls\":[]") < w2,
          "a window that WAS walked and has none says so with an empty "
          "array, which is a claim about the machine");
    check(strstr(w1, "\"text\"") == NULL || strstr(w1, "\"text\"") > w2,
          "and carries no text key, because it has no TextEdit record");

    /* An UNWALKED window now also says `controls: []`, because the IR
       requires the key on every window and has no state for "not
       looked at". The distinction did not vanish - meta carries the
       truncation note - but it no longer decides whether the document
       parses. */
    check(strstr(w2, "\"controls\":[]") != NULL,
          "an unwalked window reports an empty control list rather than "
          "omitting the key the IR requires");
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
    /* The retraction is now carried by the NOTE, not by the missing key.
       Both keys are required by the IR, so a retracted list encodes as
       an empty array and meta says a list was dropped - which is the
       fact a reader needs, and the one the absence used to imply. A
       consumer that sees `controls: []` with no note is looking at a
       window that genuinely has none. */
    check_present(out, "\"controls\":[]");
    check_present(out, "\"items\":[]");
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
    /* A WINDOW may omit its ref - `windows[].ref` is additive in v1, so a
       consumer that never heard of it is where every consumer already
       was. A CONTROL may not: `windows[].controls[].ref` is frozen, and
       omitting it makes the whole document undecodable. This assertion
       used to forbid the empty string outright, which read as a stronger
       version of the same rule and was in fact a different one. */
    check_absent(out, "\"windows\":[{\"ref\":\"\"");

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
    /* THE WINDOW'S OWN key, which is why this stops at the controls
       array. `windows[].ref` is additive in v1 and may be absent;
       `windows[].controls[].ref` is FROZEN and is always present, empty
       when nothing minted one - so scanning the whole window object for
       `"ref"` now finds a control's and says the window has one. */
    {
        const char *w1_controls = strstr(w1, "\"controls\"");
        const char *w1_ref = strstr(w1, "\"ref\"");

        check(w1_ref == NULL
                  || (w1_controls != NULL && w1_ref > w1_controls),
              "and a window the reference layer could not name carries no "
              "ref key of its own - not an empty one");
    }

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

/* A CONTROL'S `ref` IS ALWAYS PRESENT, even when nothing minted one.
 *
 * IR v1 freezes `windows[].controls[].ref`, so a consumer decodes it as
 * a required key. This producer used to OMIT it when the reference layer
 * had not named the element - a defensible distinction (absent = "not
 * minted", empty = "no reference layer") that the contract simply cannot
 * express.
 *
 * It went unnoticed until self-described windows arrived, whose controls
 * the Toolbox names and the reference layer does not: the whole scene
 * then failed to decode with `keyNotFound: Key 'ref'` and the mirror
 * went blank. The host's decode gate could not have caught it, because
 * every control in its captured fixture HAS a reference - which is why
 * the check lives here, on the producer, where an unminted control can
 * be constructed on purpose. */
static void test_a_control_without_a_reference_still_carries_the_key(void)
{
    NowScene s;
    char out[8192];
    int p;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 9, "New Old World", 0x4E4F576FUL, 1,
                              kNowSceneAnchorOk, 0);
    (void)now_scene_add_window(&s, p, "Workshop", 40, 60, 400, 600, 1);
    /* No now_scene_set_control_ref: this is the self-described case. */
    (void)now_scene_add_control(&s, 0, "Take Screenshot",
                                50, 80, 70, 220, 1, 1, 0, 0, 1);
    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "a self-described scene encodes");
    check_present(out, "\"ref\":\"\"");
}

/* Self-description already knows the CDEF procID for every control it made.
 * That fact must survive the encoder unchanged: collapsing all known roles to
 * pushButton made Workshop checkboxes and popups render as rounded buttons
 * even though control_kind.c had recorded the right answer. */
static void test_proven_control_roles_keep_their_semantics(void)
{
    static const struct {
        const char *role;
        const char *kind;
        const char *action;
        short value;
    } cases[] = {
        { "button", "pushButton", "press", 0 },
        { "checkbox", "checkBox", "press", 1 },
        { "radio", "radioButton", "press", 0 },
        { "popup", "popupMenu", "choose", 2 },
        { "scrollbar", "scrollBar", "scroll", 4 },
        { "group", "groupBox", NULL, 0 },
        { "progress", "progressIndicator", NULL, 35 },
        { "triangle", "disclosureTriangle", "press", 1 },
        { "listBox", "listBox", NULL, 0 }
    };
    NowScene s;
    char out[16384];
    int p;
    size_t i;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 9, "New Old World", 0x4E4F576FUL, 1,
                              kNowSceneAnchorOk, 0);
    (void)now_scene_add_window(&s, p, "Workshop", 40, 60, 400, 600, 1);
    for (i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        int index;

        (void)now_scene_add_control(&s, 0, cases[i].role,
                                    (short)(20 + i * 20), 20,
                                    (short)(36 + i * 20), 180,
                                    1, 1, cases[i].value, 0, 100);
        index = now_scene_last_control(&s, 0);
        now_scene_set_control_role(&s, 0, index, cases[i].role);
        if (strcmp(cases[i].role, "popup") == 0) {
            now_scene_set_control_semantic_value(&s, 0, index, "8-bit");
        } else if (strcmp(cases[i].role, "listBox") == 0) {
            now_scene_set_control_semantic_value(&s, 0, index, "Rome");
        }
        check(index >= 0, "the proven control was added");
    }

    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the proven control scene encodes");
    for (i = 0; i < sizeof cases / sizeof cases[0]; ++i) {
        char kind[96];
        char action[64];

        snprintf(kind, sizeof kind, "\"kind\":\"%s\"", cases[i].kind);
        check_present(out, kind);
        if (cases[i].action != NULL) {
            snprintf(action, sizeof action, "\"action\":\"%s\"",
                     cases[i].action);
            check_present(out, action);
        }
    }
    check_present(out, "\"kind\":\"checkBox\",\"action\":\"press\","
                       "\"state\":\"on\"");
    check_present(out, "\"kind\":\"radioButton\",\"action\":\"press\","
                       "\"state\":\"off\"");
    check_present(out, "\"kind\":\"popupMenu\",\"action\":\"choose\","
                       "\"value\":\"8-bit\"");
    check_present(out, "\"kind\":\"progressIndicator\","
                       "\"value\":\"35\"");
    check_present(out, "\"kind\":\"listBox\",\"value\":\"Rome\","
                       "\"provenance\":\"guest-semantic-assist\","
                       "\"completeness\":\"partial\"");
}

/* The role a walk may claim, pinned against a MEASUREMENT.
 *
 * These four controls are Mail's "Is your computer set up for Internet
 * access?" alert, read out of the running guest's memory on 2026-08-03
 * by walking WindowList through the emulator's monitor: three push
 * buttons at ControlRecord+40 titled 'Yes', 'No' and 'Set Up Now', each
 * 20 pixels high with min 0 and max 1, beside a real scroll bar.
 *
 * The rule they broke was `min != max means scrollbar`, so all three
 * buttons were called scroll bars. They drew as tracks with no labels,
 * and a click on one sent a page-scroll part instead of a button press:
 * the mirror could not dismiss the alert, and the alert held the
 * machine. This test exists so that never silently returns. */
static void test_unproven_controls_are_unknown_and_unactionable(void)
{
    NowScene s;
    char out[8192];
    int p;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 9, "Mail", 0x6D6F7373UL, 1,
                              kNowSceneAnchorOk, 0);
    (void)now_scene_add_window(&s, p, "Alert", 30, 40, 200, 400, 1);

    /* min 0 max 1 - the values that used to say "scroll bar". */
    (void)now_scene_add_control(&s, 0, "Yes", 85, 70, 105, 152, 1, 1, 0, 0, 1);
    (void)now_scene_add_control(&s, 0, "No", 85, 201, 105, 259, 1, 1, 0, 0, 1);
    (void)now_scene_add_control(&s, 0, "Set Up Now", 85, 271, 105, 356,
                                1, 1, 0, 0, 1);
    /* A real vertical scroll bar: untitled, 16 across, long. */
    (void)now_scene_add_control(&s, 0, "", 20, 380, 180, 396, 1, 1, 0, 0, 100);
    /* Untitled, 20 high and long: NOT thin enough to be a scroll bar,
       which is the case the old 20-pixel threshold swallowed. */
    (void)now_scene_add_control(&s, 0, "", 120, 70, 140, 300, 1, 1, 0, 0, 1);
    /* TITLED and scroll-bar-shaped: 16 high, 120 wide. Older applications
       really do use short wide buttons, and shape alone would call this
       one a scroll bar. Only the title rule saves it, which is why this
       row is here - without it that rule is decoration. */
    (void)now_scene_add_control(&s, 0, "Cancel", 150, 70, 166, 190,
                                1, 1, 0, 0, 1);

    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the alert encodes");

    check(strstr(out, "\"title\":\"Yes\"") != NULL
          && strstr(out, "\"title\":\"No\"") != NULL
          && strstr(out, "\"title\":\"Set Up Now\"") != NULL,
          "the buttons keep the titles the walk read from +40");
    check(strstr(out, "{\"role\":\"unknown\",\"title\":\"Yes\"") != NULL
          && strstr(out, "{\"role\":\"unknown\",\"title\":\"\","
                    "\"rect\":{\"l\":380,\"t\":20,\"r\":396,\"b\":180}")
             != NULL,
          "neither a title, range nor shape fabricates a control kind");
    check_present(out, "\"semantic\":{\"knowledge\":\"unknown\"");
    check_absent(out, "\"action\":\"press\"");
    check_absent(out, "\"action\":\"scroll\"");
}

static void test_dialog_items_carry_v2_semantics(void)
{
    NowScene s;
    char out[16384];
    int p;
    NowSceneDialogItem *item;

    now_scene_begin(&s, 1, 0.0, "peek", 640, 480, 0, 0);
    p = now_scene_add_process(&s, 0, 9, "Date & Time", 0, 1,
                              kNowSceneAnchorOk, 0);
    (void)now_scene_add_window(&s, p, "Date Formats", 40, 60, 300, 500, 1);
    now_scene_set_window_kind(&s, 0, 2);

    (void)now_scene_add_dialog_item(&s, 0, 1,
                                    kNowSceneSemanticPopupMenu, "Region:",
                                    10, 20, 30, 180, 1, 1);
    item = &s.dialog_items[0];
    item->value_known = 1;
    strcpy(item->value, "Custom");
    strcpy(item->ref, "now-element-popup");

    (void)now_scene_add_dialog_item(&s, 0, 2,
                                    kNowSceneSemanticEditText, "",
                                    40, 20, 60, 80, 1, 1);
    item = &s.dialog_items[1];
    item->value_known = 1;
    strcpy(item->value, "9");
    item->focus_known = 1;
    item->focused = 1;
    item->selection_known = 1;
    item->selection_start = 0;
    item->selection_end = 1;

    (void)now_scene_add_dialog_item(&s, 0, 3,
                                    kNowSceneSemanticStaticText, "Prefix:",
                                    40, 90, 60, 150, 1, 1);
    item = &s.dialog_items[2];
    item->value_known = 1;
    strcpy(item->value, "Prefix:");

    (void)now_scene_add_dialog_item(&s, 0, 4,
                                    kNowSceneSemanticCheckBox,
                                    "Leading zero", 80, 20, 96, 180, 1, 1);
    item = &s.dialog_items[3];
    item->state_known = 1;
    item->state_on = 1;

    (void)now_scene_add_dialog_item(&s, 0, 5,
                                    kNowSceneSemanticRadioButton, "Off",
                                    105, 20, 121, 80, 1, 1);
    (void)now_scene_add_dialog_item(&s, 0, 6,
                                    kNowSceneSemanticPushButton, "OK",
                                    150, 300, 170, 380, 1, 1);
    item = &s.dialog_items[5];
    item->default_known = 1;
    item->is_default = 1;

    (void)now_scene_add_dialog_item(
        &s, 0, 7, kNowSceneSemanticCheckBox,
        "Set Daylight-Saving Time Automatically", 125, 20, 141, 300,
        1, 1);
    (void)now_scene_add_dialog_item(
        &s, 0, 8, kNowSceneSemanticUnknown, "Custom display",
        20, 20, 40, 180, 1, 1);
    (void)now_scene_add_dialog_item(
        &s, 0, 9, kNowSceneSemanticPanel, "Workshop sidebar",
        20, 10, 260, 160, 1, 1);
    now_scene_set_dialog_item_provenance(&s, 0, 8,
                                         "guest-workshop-model");

    check(now_scene_encode(&s, out, sizeof out, NULL) == kNowSceneEncodeOk,
          "the v2 dialog encodes");
    check_present(out, "\"version\":2");
    check_present(out, "\"kind\":\"popupMenu\",\"action\":\"choose\"");
    check_present(out, "\"value\":\"Custom\"");
    check_present(out, "\"kind\":\"editText\",\"action\":\"edit\"");
    check_present(out, "\"selection\":{\"start\":0,\"end\":1}");
    check_present(out, "\"focused\":true");
    check_present(out, "\"kind\":\"staticText\"");
    check_present(out, "\"kind\":\"checkBox\",\"action\":\"press\","
                       "\"state\":\"on\"");
    check_present(out, "\"kind\":\"radioButton\"");
    check_present(out, "\"isDefault\":true");
    check_present(out, "\"provenance\":\"guest-ditl\"");
    check_present(out,
                  "\"title\":\"Set Daylight-Saving Time Automatically\"");
    check_present(out, "\"title\":\"Custom display\",\"rect\":");
    check_present(out, "\"knowledge\":\"unknown\","
                       "\"provenance\":\"guest-ditl\"");
    check_present(out, "\"kind\":\"panel\"");
    check_present(out, "\"provenance\":\"guest-workshop-model\"");

    /* Only the push button had a validated aDefItem match. Unknown is
       absence, not false: a renderer must not erase an unobserved default
       by treating every other item as explicitly non-default. */
    {
        const char *items = strstr(out, "\"dialogItems\":[");
        const char *default_key = strstr(items, "\"isDefault\"");

        check(items != NULL && default_key != NULL
              && strstr(default_key + 1, "\"isDefault\"") == NULL,
              "isDefault is emitted once; unobserved defaults stay absent");
    }
}

int main(void)
{
    test_coverage_and_incarnation_reach_the_wire();
    test_proven_control_roles_keep_their_semantics();
    test_unproven_controls_are_unknown_and_unactionable();
    test_dialog_items_carry_v2_semantics();
    test_a_control_without_a_reference_still_carries_the_key();
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
