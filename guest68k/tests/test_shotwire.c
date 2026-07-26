/*
 * test_shotwire.c - the capture transfer's arithmetic and envelopes, under
 * the host cc. scripts/test-native runs it; the manifest there is the gate.
 *
 * WHAT IS WORTH TESTING is what a person cannot see going wrong. A capture
 * that fails to send is obvious the first time. These are not:
 *
 *   - `bytes` disagreeing with what is actually streamed. The receiver
 *     sizes its staging from that number, so a stream one palette short
 *     either truncates the picture or hangs the transfer waiting for bytes
 *     nobody will send.
 *   - the visible-row decision quietly reverting to the screen's rowBytes.
 *     On the 180c they are the same number (640), so the bug would be
 *     invisible on the machine this is for and would shear every capture
 *     taken on the Quadra, whose rowBytes is 1024.
 *   - offset -> row arithmetic off by one row: a plausible, sheared image.
 *   - capture.begin drifting from the envelope the host already decodes.
 */
#include "n68_shotwire.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

static void check(int cond, const char *what)
{
    if (!cond) {
        printf("FAIL %s\n", what);
        ++g_failures;
    }
}

static void check_long(long got, long want, const char *what)
{
    if (got != want) {
        printf("FAIL %s: got %ld want %ld\n", what, got, want);
        ++g_failures;
    }
}

static void check_str(const char *got, const char *want, const char *what)
{
    if (strcmp(got, want) != 0) {
        printf("FAIL %s:\n  got  %s\n  want %s\n", what, got, want);
        ++g_failures;
    }
}

static void test_the_180c_frame(void)
{
    N68ShotWirePlan p;

    check(n68_shotwire_plan(640, 480, 8, &p), "640x480x8 is sendable");
    check_long(p.row_bytes, 640, "the visible row");
    check_long(p.palette_bytes, 768, "256 RGB triples");
    /* The number capture.begin promises and the source must produce
     * exactly: palette + rows, not rows alone. */
    check_long(p.total, 768 + 640 * 480, "bytes includes the palette");
    check_long(p.total, 307968, "the 180c's whole raw frame");
}

static void test_the_row_sent_is_the_visible_one(void)
{
    N68ShotWirePlan p;

    /* The Quadra 800 drives a 640-pixel screen with rowBytes 1024. If this
     * lane ever sends the screen's rowBytes instead of the visible row,
     * the 180c (where they are equal) will not notice and every emulator
     * capture will shear. */
    (void)n68_shotwire_plan(640, 480, 8, &p);
    check(p.row_bytes == p.width,
          "the row on the wire is the visible row, not the framebuffer's");
}

static void test_geometry_this_lane_will_not_send(void)
{
    N68ShotWirePlan p;

    check(!n68_shotwire_plan(640, 480, 1, &p), "1-bit is refused");
    check(!n68_shotwire_plan(640, 480, 16, &p), "16-bit is refused");
    check_long(p.total, 0, "a refused plan is left zeroed, not half-filled");
    check(!n68_shotwire_plan(0, 480, 8, &p), "no width, no plan");
    check(!n68_shotwire_plan(640, -1, 8, &p), "no height, no plan");
}

static void test_where_a_byte_comes_from(void)
{
    N68ShotWirePlan p;
    long row = 0, col = 0;

    (void)n68_shotwire_plan(640, 480, 8, &p);

    check(n68_shotwire_locate(&p, 0, &row, &col), "offset 0 is locatable");
    check(row == -1 && col == 0, "offset 0 is the first palette byte");

    check(n68_shotwire_locate(&p, 767, &row, &col), "the last palette byte");
    check(row == -1 && col == 767, "still the palette at 767");

    check(n68_shotwire_locate(&p, 768, &row, &col), "the first pixel byte");
    check(row == 0 && col == 0, "768 is row 0, column 0 - not row 1");

    check(n68_shotwire_locate(&p, 768 + 640, &row, &col), "the second row");
    check(row == 1 && col == 0, "one row on from the first pixel");

    check(n68_shotwire_locate(&p, 768 + 640 * 479 + 639, &row, &col),
          "the last byte of the last row");
    check(row == 479 && col == 639, "the bottom-right pixel");
}

static void test_past_the_end_is_not_a_row(void)
{
    N68ShotWirePlan p;
    long row = 0, col = 0;

    (void)n68_shotwire_plan(640, 480, 8, &p);
    check(!n68_shotwire_locate(&p, p.total, &row, &col),
          "one past the end is refused");
    check(row == -1 && col == -1, "and reports no position at all");
    check(!n68_shotwire_locate(&p, -1, &row, &col), "a negative offset too");
}

static void test_capture_begin_matches_the_envelope_the_host_decodes(void)
{
    N68ShotWirePlan p;
    char json[kN68ShotWireJsonCap];
    long n;

    (void)n68_shotwire_plan(640, 480, 8, &p);
    n = n68_shotwire_begin_json(&p, 7, 3, 213, 0, json, (long)sizeof json);
    check(n > 0, "capture.begin fits its buffer");
    /* Field for field and in order, as guest/src/wire.c sends it. */
    check_str(json,
              "{\"type\":\"capture.begin\",\"id\":7,\"transfer\":3,"
              "\"width\":640,\"height\":480,\"depth\":8,"
              "\"rowBytes\":640,\"bytes\":307968,\"paletteBytes\":768,"
              "\"encoding\":\"raw\",\"captureMs\":213,\"encodeMs\":0}",
              "capture.begin");
    check_long(n, (long)strlen(json), "the returned length is the length");
}

static void test_capture_begin_refuses_a_buffer_it_would_overflow(void)
{
    N68ShotWirePlan p;
    char tiny[40];

    (void)n68_shotwire_plan(640, 480, 8, &p);
    check_long(n68_shotwire_begin_json(&p, 7, 3, 0, 0, tiny,
                                       (long)sizeof tiny),
               0, "a truncated capture.begin is not sent");
    check_str(tiny, "", "and leaves nothing half-built");
}

static void test_capture_end_both_ways(void)
{
    char json[kN68ShotWireJsonCap];

    (void)n68_shotwire_end_json(7, 3, 1, json, (long)sizeof json);
    check_str(json, "{\"type\":\"capture.end\",\"id\":7,\"transfer\":3,"
                    "\"ok\":true}", "capture.end ok");
    /* The failure envelope matters more than the success one: the receiver
     * is already staging bytes for this id, and this is what stops it. */
    (void)n68_shotwire_end_json(7, 3, 0, json, (long)sizeof json);
    check_str(json, "{\"type\":\"capture.end\",\"id\":7,\"transfer\":3,"
                    "\"ok\":false}", "capture.end failed");
}

int main(void)
{
    test_the_180c_frame();
    test_the_row_sent_is_the_visible_one();
    test_geometry_this_lane_will_not_send();
    test_where_a_byte_comes_from();
    test_past_the_end_is_not_a_row();
    test_capture_begin_matches_the_envelope_the_host_decodes();
    test_capture_begin_refuses_a_buffer_it_would_overflow();
    test_capture_end_both_ways();

    if (g_failures != 0) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_shotwire: all checks passed\n");
    return 0;
}
