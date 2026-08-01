/* Native test for the IR v1 encoder (src/scene/scene_json.c).
 *
 * Two things are being pinned here and they pull in opposite directions.
 *
 * ABSENCE. `menubar`, `menus`, `controls`, `text`, `kind`, `display` and
 * `desktopItems` must not appear AT ALL. An empty array would assert
 * "this window has no controls"; absence says "this producer does not
 * report controls". A test that only checked the keys we DO emit would
 * pass while the encoder quietly shipped `"controls":[]` and taught every
 * consumer a false fact about the machine.
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

    check_absent(out, "controls");
    check_absent(out, "menubar");
    check_absent(out, "menus");
    check_absent(out, "\"text\"");
    check_absent(out, "\"kind\"");
    check_absent(out, "display");
    check_absent(out, "desktopItems");
    check_absent(out, "items");
    check_absent(out, "island");
    /* meta.bytes is the encoded size, and the encode is what is
       happening; latencyMs is absent until something measures it. */
    check_absent(out, "\"bytes\"");
    check_absent(out, "latencyMs");
    /* But meta.errors is EMITTED even when empty: it is a list of things
       that went wrong during a walk that did happen, not a plane this
       producer declines to report. */
    check_present(out, "\"errors\":[");
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
static void test_size_against_the_control_cap(void)
{
    NowScene s;
    long small, realistic;
    int i;

    build_small(&s);
    small = now_scene_encoded_size(&s);
    printf("  scene size: 4 processes / 3 windows = %ld bytes\n", small);

    now_scene_begin(&s, 1, 1000000000.0, "peek", 832, 624, 20000, 3600);
    for (i = 0; i < 24; ++i) {
        char name[kNowSceneNameMax];
        int p;

        snprintf(name, sizeof name, "Application %d", i);
        p = now_scene_add_process(&s, 0, (unsigned long)(29884417 + i * 1024),
                                  name, 0x4D414353UL, i == 0,
                                  kNowSceneAnchorOk, 19990);
        (void)now_scene_add_window(&s, p, "Untitled document", 20, 4, 300,
                                   420, 1);
        if (i % 3 == 0) {
            (void)now_scene_add_window(&s, p, "Another window", 40, 40, 320,
                                       440, 1);
        }
    }
    realistic = now_scene_encoded_size(&s);
    printf("  scene size: %d processes / %d windows = %ld bytes\n",
           (int)s.proc_count, (int)s.window_count, realistic);
    check(realistic > 4096,
          "a realistic desktop exceeds the 4096-byte control cap, so a "
          "scene is a transfer and not a control message");
    check(small < realistic, "and it grows with the machine");
}

int main(void)
{
    test_produced_fields();
    test_unproduced_planes_are_absent();
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
