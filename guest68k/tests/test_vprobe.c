/* Host-side test for NOW-68K's vprobe row table, arithmetic and renderers
 * (src/n68_vprobe.c).
 *
 * The MEASURING half (src/vprobe68.c) cannot be reached from here: it
 * needs a screen, a Microseconds trap and a 68030, and none of those exist
 * on the machine running this file. Saying "vprobe is tested" would
 * therefore be a misleading summary. What IS tested is everything that can
 * be wrong without a Macintosh:
 *
 *   - the geometry check that stands between the probe and a bus error.
 *     This is the one piece whose failure mode on metal is a dead machine
 *     rather than a wrong number, so it is checked here rather than
 *     watched there: every field that can be wrong is made wrong in turn
 *     and the refusal is named.
 *   - the budget scaling. It is what keeps a slow machine's probe from
 *     going deaf for longer than the host's ~65 s death window, and it
 *     runs on measured numbers nobody can predict - so its behaviour at
 *     the edges (an unmeasurably fast slice, a budget smaller than one
 *     step, alignment) is pinned here.
 *   - the linearity prediction, which is the whole point of the partial
 *     row: a prediction that quietly overflowed 32 bits would make the row
 *     read as a spectacular non-linearity.
 *   - the reply-size bound. A command.result cannot page, so a table that
 *     does not fit is not a short table, it is no reply at all. The
 *     worst-case table is BUILT here and measured against
 *     NOW68K_VPROBE_JSON_MAX, and the renderer is checked to emit whole
 *     rows or nothing at every capacity below it.
 *   - sanitizing, for the same reason n68_proclist.c sanitizes: one
 *     high-bit byte in a JSON string is invalid UTF-8 and costs the whole
 *     frame, not one row.
 *
 * THIRTY-TWO BITS. n68_vprobe.c bounds its intermediates against a
 * hardcoded 32-bit ceiling rather than against this host's 64-bit `long`,
 * precisely so the arithmetic tested here is the arithmetic the 180c will
 * run. Where a case exists only to pin that, it says so.
 *
 * The parser is deliberately dumb - substring searches over the emitted
 * text, not a JSON reader. A test that parsed with the guest's own scanner
 * would be testing one half twice.
 *
 * cc -Wall -Wextra -Werror -I ../src test_vprobe.c ../src/n68_vprobe.c \
 *    ../src/numfmt.c ../src/n68_cmdresult.c
 */

#include "n68_vprobe.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do { \
        g_checks++; \
        if (!(cond)) { \
            g_failures++; \
            printf("FAIL: %s (%s:%d)\n", msg, __FILE__, __LINE__); \
        } \
    } while (0)

#define CHECK_STR(got, want, msg) do { \
        g_checks++; \
        if (strcmp((got), (want)) != 0) { \
            g_failures++; \
            printf("FAIL: %s - got \"%s\", want \"%s\" (%s:%d)\n", \
                   msg, (got), (want), __FILE__, __LINE__); \
        } \
    } while (0)

/* The PowerBook 180c as configured: 640x480, 8 bits, one byte per pixel.
   Every geometry case below starts from this and breaks one thing. */
enum {
    kBase   = 0xFEE08000UL,
    kRow    = 640,
    kWidth  = 640,
    kHeight = 480,
    kDepth  = 8,
    kFrame  = kRow * kHeight        /* 307200 */
};

/* ---- geometry ----------------------------------------------------------- */

static void test_geometry_accepts_the_180c(void)
{
    long bytes = -1;

    CHECK(n68_vprobe_geometry_ok(kBase, kRow, kWidth, kHeight, kDepth,
                                 &bytes) == kN68VProbeGeomOK,
          "the 180c's own screen geometry is accepted");
    CHECK(bytes == kFrame, "and the frame size is rowBytes * height");
}

static void test_geometry_refuses_every_broken_field(void)
{
    long bytes = -1;

    /* Each case breaks exactly one field, because a check that only fires
       when two things are wrong is a check that does not fire. */
    CHECK(n68_vprobe_geometry_ok(0, kRow, kWidth, kHeight, kDepth, &bytes)
              == kN68VProbeGeomNoBase, "a NULL base is refused");
    CHECK(bytes == 0, "and no size is handed back on a refusal");

    CHECK(n68_vprobe_geometry_ok(kBase + 1, kRow, kWidth, kHeight, kDepth,
                                 &bytes) == kN68VProbeGeomOddBase,
          "an odd base is refused - a 68030 address-errors on it");

    CHECK(n68_vprobe_geometry_ok(kBase, kRow, 0, kHeight, kDepth, &bytes)
              == kN68VProbeGeomBadBounds, "a zero width is refused");
    CHECK(n68_vprobe_geometry_ok(kBase, kRow, kWidth, -1, kDepth, &bytes)
              == kN68VProbeGeomBadBounds, "a negative height is refused");
    CHECK(n68_vprobe_geometry_ok(kBase, kRow, 40000, kHeight, kDepth, &bytes)
              == kN68VProbeGeomBadBounds,
          "a width no classic screen has is refused");

    CHECK(n68_vprobe_geometry_ok(kBase, kRow, kWidth, kHeight, 7, &bytes)
              == kN68VProbeGeomBadDepth, "a depth of 7 is not a QD depth");
    CHECK(n68_vprobe_geometry_ok(kBase, kRow, kWidth, kHeight, 0, &bytes)
              == kN68VProbeGeomBadDepth, "a depth of 0 is refused");

    CHECK(n68_vprobe_geometry_ok(kBase, 320, kWidth, kHeight, kDepth, &bytes)
              == kN68VProbeGeomShortRow,
          "rowBytes that cannot hold one row of pixels is refused");
    CHECK(n68_vprobe_geometry_ok(kBase, 0, kWidth, kHeight, kDepth, &bytes)
              == kN68VProbeGeomShortRow, "rowBytes of 0 is refused");
    CHECK(n68_vprobe_geometry_ok(kBase, 99999, kWidth, kHeight, kDepth,
                                 &bytes) == kN68VProbeGeomHugeRow,
          "rowBytes larger than any screen is refused");

    /* 2048 x 4096 at 32 bits: every field is inside its own bound
       (rowBytes is exactly the 8192 ceiling, the rectangle is a legal one)
       and the frame is still 32 MB. The frame check is not implied by the
       field checks. */
    CHECK(n68_vprobe_geometry_ok(kBase, 8192, 2048, 4096, 32, &bytes)
              == kN68VProbeGeomHugeFrame,
          "a frame bigger than this Mac's memory is refused");

    /* The 32-bit wrap. On this 64-bit host nothing wraps naturally, which
       is exactly why the check is written against a 32-bit ceiling: a base
       near the top of a 68030's address space plus a frame must be
       refused here the way it would be there. */
    CHECK(n68_vprobe_geometry_ok(0xFFFF0000UL, kRow, kWidth, kHeight, kDepth,
                                 &bytes) == kN68VProbeGeomWraps,
          "base + size leaving the 32-bit address space is refused");

    /* And a refusal always has something to say. */
    CHECK(strcmp(n68_vprobe_geom_reason(kN68VProbeGeomOddBase), "") != 0,
          "every refusal carries a sentence");
    CHECK(strcmp(n68_vprobe_geom_reason(kN68VProbeGeomOK), "ok") == 0,
          "and OK says ok");
}

/* ---- formatting --------------------------------------------------------- */

static void test_bandwidth_formatting(void)
{
    char v[kN68VProbeValueCap];

    /* The PB1400c's own 32-bit row, so this file pins the format against a
       measurement that exists: 937 KB in 104.1 ms is 8.7 MB/s
       (docs/vram-readout.md). */
    n68_vprobe_bw_value(v, (long)sizeof v, 959488L, 959488L, 104100UL);
    CHECK_STR(v, "104.1 ms 8.7 MB/s 100%", "the 1400c's 32-bit row");

    /* A row measured over part of the screen says so. */
    n68_vprobe_bw_value(v, (long)sizeof v, kFrame / 4, kFrame, 400000UL);
    CHECK(strstr(v, "25%") != NULL,
          "a quarter-frame pass reports 25%, so nobody compares it with a "
          "whole one");

    /* No measurement is not a fast measurement. */
    n68_vprobe_bw_value(v, (long)sizeof v, kFrame, kFrame, 0UL);
    CHECK_STR(v, "0.0 ms too fast to time",
              "a zero interval never becomes a bandwidth");
    n68_vprobe_bw_value(v, (long)sizeof v, 0L, kFrame, 1000UL);
    CHECK_STR(v, "no measurement", "zero bytes is not a measurement either");

    /* The longest value the probe can emit still fits the row cap - this
       is what the reply-size bound below is entitled to assume. */
    n68_vprobe_bw_value(v, (long)sizeof v, 4000000L, 4000000L, 1234567UL);
    CHECK(strlen(v) < (size_t)kN68VProbeValueCap,
          "even the widest bandwidth value fits a row");

    n68_vprobe_ms_value(v, (long)sizeof v, 104123UL);
    CHECK_STR(v, "104.1", "milliseconds carry one decimal");
    n68_vprobe_ms_value(v, (long)sizeof v, 0UL);
    CHECK_STR(v, "0.0", "and zero is zero, not empty");

    n68_vprobe_rate_value(v, (long)sizeof v, 959488L, 104100UL);
    CHECK_STR(v, "8.7 MB/s", "the rate-only value the summary row carries");
    n68_vprobe_rate_value(v, (long)sizeof v, 959488L, 0UL);
    CHECK_STR(v, "n/a", "and it refuses to rate an unmeasurable pass");

    /* "movem.l x8 " + the rate must fit one row, because that IS the
       summary row the console gets. */
    {
        char merged[kN68VProbeValueCap];
        char rate[16];

        n68_vprobe_rate_value(rate, (long)sizeof rate, kFrame, 42000UL);
        CHECK(strlen("movem.l x8 ") + strlen(rate)
                  < (size_t)kN68VProbeValueCap,
              "the winning method's name and its rate fit one row together");
        (void)merged;
    }
}

/* ---- budget scaling ----------------------------------------------------- */

static void test_scaling_bounds_a_slow_machine(void)
{
    long got;

    /* A slice of 16 rows (10240 bytes) that took 40 ms predicts a full
       307200-byte pass at 1.2 s - inside a 1.2 s budget, so the whole
       frame is read. */
    got = n68_vprobe_scaled_bytes(40000UL, 10240L, kFrame, 1200000UL, 32L);
    CHECK(got == kFrame, "a pass that fits the budget reads the whole frame");

    /* Ten times slower: the same slice at 400 ms predicts 12 s, so the
       pass must be cut to about a tenth. */
    got = n68_vprobe_scaled_bytes(400000UL, 10240L, kFrame, 1200000UL, 32L);
    CHECK(got < kFrame, "a pass that would blow the budget is shortened");
    CHECK(got >= kFrame / 12 && got <= kFrame / 8,
          "and shortened to about the fraction the budget buys");
    CHECK(got % 32 == 0, "every extent is a whole number of 32-byte steps");

    /* A machine so slow that not even one step fits still measures one
       step: a row saying 'too slow to measure' is worse than a row with a
       number and a 0% next to it. */
    got = n68_vprobe_scaled_bytes(1000000UL, 32L, kFrame, 100UL, 32L);
    CHECK(got == 32, "an impossible budget still measures one step");

    /* A slice too fast for the timer is not evidence of a slow pass. */
    got = n68_vprobe_scaled_bytes(0UL, 10240L, kFrame, 1200000UL, 32L);
    CHECK(got == kFrame,
          "an unmeasurable slice reads the whole frame rather than "
          "shortening on no evidence");

    /* Degenerate inputs do not produce a read at all. */
    CHECK(n68_vprobe_scaled_bytes(40000UL, 10240L, 0L, 1200000UL, 32L) == 0,
          "a zero frame reads nothing");
    CHECK(n68_vprobe_scaled_bytes(40000UL, 10240L, 16L, 1200000UL, 32L) == 0,
          "a frame smaller than one step reads nothing");

    /* Alignment is honoured even when the frame is not a multiple of it. */
    got = n68_vprobe_scaled_bytes(0UL, 0L, 1000L, 0UL, 32L);
    CHECK(got == 992, "an unaligned frame is trimmed down to a whole step");
}

static void test_prediction_is_linear_and_does_not_overflow(void)
{
    unsigned long got;

    /* Straight scaling up: 16 rows in 40 ms predicts 480 rows at 1.2 s. */
    got = n68_vprobe_predict_us(40000UL, 10240L, kFrame);
    CHECK(got > 1150000UL && got < 1250000UL,
          "a 30x larger read is predicted at about 30x the cost");

    /* And down, which is the direction the partial row uses: a tenth of
       the frame should be a tenth of the time. docs/vram-readout.md's own
       case - the 1400c predicted 10.4 ms for 60 of 600 rows against
       104.1 ms for the frame. */
    got = n68_vprobe_predict_us(104100UL, 959488L, 959488L / 10);
    CHECK(got > 10000UL && got < 10800UL,
          "a tenth of a frame is predicted at about a tenth of the cost");

    /* THE 32-BIT CASE. ref_us * want_bytes is 3.7e11 here - it would wrap
       on the 180c and produce a prediction smaller than the measurement,
       which reads as a spectacular and completely false non-linearity.
       The implementation halves both byte counts until the product fits;
       this pins that it still answers, and answers sensibly. */
    got = n68_vprobe_predict_us(1200000UL, 307200L, 307200L);
    CHECK(got > 1150000UL && got < 1250000UL,
          "a full-frame prediction from a full-frame measurement is "
          "itself, not a wrapped number");

    /* Nothing to predict from. */
    CHECK(n68_vprobe_predict_us(0UL, 1000L, 1000L) == 0,
          "no reference time, no prediction");
    CHECK(n68_vprobe_predict_us(1000UL, 0L, 1000L) == 0,
          "no reference size, no prediction");
    CHECK(n68_vprobe_predict_us(1000UL, 1000L, 0L) == 0,
          "nothing wanted, nothing predicted");
}

/* ---- the table and its sanitizing --------------------------------------- */

static void test_rows_are_sanitized_and_bounded(void)
{
    N68VProbeTable t;
    char json[NOW68K_VPROBE_JSON_MAX];
    size_t i;
    int added;

    n68_vprobe_table_init(&t);
    CHECK(t.count == 0 && t.dropped == 0, "a fresh table is empty");

    (void)n68_vprobe_add(&t, "quo\"te\\d", "hi\x01there\xE9");
    CHECK_STR(t.rows[0].label, "quo'te'd",
              "a quote or backslash in a label cannot reopen a JSON string");
    CHECK_STR(t.rows[0].value, "hi.there.",
              "a control byte or a MacRoman high byte becomes a dot - one "
              "high byte would make the whole frame invalid UTF-8");

    /* Truncation at the cap, not past it. */
    n68_vprobe_add(&t, "0123456789ABCDEFGHIJKLMNOP",
                   "0123456789012345678901234567890123456789");
    CHECK(strlen(t.rows[1].label) == (size_t)kN68VProbeLabelCap - 1,
          "an over-long label is truncated to the cap");
    CHECK(strlen(t.rows[1].value) == (size_t)kN68VProbeValueCap - 1,
          "an over-long value is truncated to the cap");

    /* Filling past the end is reported, not silently lost. */
    for (i = t.count; i < (size_t)kN68VProbeMaxRows; ++i) {
        CHECK(n68_vprobe_add(&t, "row", "value") == 1,
              "rows up to the cap are stored");
    }
    added = n68_vprobe_add(&t, "one too many", "value");
    CHECK(added == 0 && t.dropped == 1,
          "a row past the end is refused and counted, not dropped quietly");
    CHECK(t.count == (short)kN68VProbeMaxRows,
          "and the table does not grow past its own bound");

    /* Whatever was sanitized in, the rendered page is plain ASCII. */
    CHECK(n68_vprobe_render_json(&t, 7, json, (long)sizeof json) > 0,
          "a full table renders");
    for (i = 0; i < strlen(json); ++i) {
        CHECK((unsigned char)json[i] >= 0x20 && (unsigned char)json[i] < 0x7F,
              "the whole reply is printable ASCII");
        if ((unsigned char)json[i] < 0x20 || (unsigned char)json[i] >= 0x7F) {
            break;   /* one report, not one per byte */
        }
    }
}

/* ---- the reply-size bound ------------------------------------------------ */

/* The worst case a table can be: every row at both caps. Built rather than
   reasoned about, because a bound nobody re-measures stops being one. */
static void fill_worst_case(N68VProbeTable *t)
{
    static const char kLabel[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    static const char kValue[] =
        "abcdefghijklmnopqrstuvwxyzabcdefghijklmnopqrstuvwxyz";
    int i;

    n68_vprobe_table_init(t);
    for (i = 0; i < (int)kN68VProbeMaxRows; ++i) {
        (void)n68_vprobe_add(t, kLabel, kValue);
    }
}

static void test_worst_case_reply_fits_the_stated_bound(void)
{
    N68VProbeTable t;
    char json[NOW68K_VPROBE_JSON_MAX + 64];
    long n;

    fill_worst_case(&t);
    n = n68_vprobe_render_json(&t, 2147483647L, json, (long)sizeof json);
    CHECK(n > 0, "the worst-case table renders");
    CHECK(n == (long)strlen(json),
          "the returned length is what the caller should enqueue");
    CHECK(n <= NOW68K_VPROBE_JSON_MAX,
          "the worst case is inside NOW68K_VPROBE_JSON_MAX - the number "
          "commands68.h asserts a command.result buffer against");
    /* And the bound is not wildly loose: a bound with a whole spare row in
       it would let a seventeenth row in without anyone noticing. */
    CHECK(n > NOW68K_VPROBE_JSON_MAX - 2 * NOW68K_VPROBE_ROW_MAX,
          "and the bound is tight enough to be a bound");

    CHECK(strstr(json, "\"type\":\"command.result\"") != NULL,
          "it is a command.result");
    CHECK(strstr(json, "\"id\":2147483647") != NULL,
          "the request id is echoed, including the largest one a 32-bit "
          "long can carry");
    CHECK(strstr(json, "\"ok\":true") != NULL, "and it is an ok reply");
    CHECK(strstr(json, "\"output\":{\"vprobe\":[[\"") != NULL,
          "carrying output.vprobe as the contract's row array");
    CHECK(strstr(json, "]]}}") != NULL, "closed properly");
}

static void test_a_reply_that_does_not_fit_is_no_reply(void)
{
    N68VProbeTable t;
    char json[NOW68K_VPROBE_JSON_MAX + 64];
    long cap;

    fill_worst_case(&t);

    /* At every capacity below the whole thing, the renderer must produce
       either a complete object or nothing. Half a JSON object decodes to
       nothing on the host and costs the whole reply, so a truncated page
       is strictly worse than no page - and the caller can only answer
       honestly if it can tell the difference. */
    for (cap = 0; cap < (long)sizeof json; ++cap) {
        long n = n68_vprobe_render_json(&t, 1, json, cap);

        if (n == 0) {
            CHECK(cap == 0 || json[0] == '\0',
                  "a refusal leaves an empty string, never a fragment");
            continue;
        }
        CHECK(n < cap, "a reply always leaves room for its terminator");
        CHECK(json[n] == '\0', "and is terminated where it says it is");
        CHECK(strstr(json, "]]}}") != NULL,
              "a reply that came back at all is a complete object");
    }
}

/* ---- the console renderers ----------------------------------------------- */

static void test_text_render_is_a_table(void)
{
    N68VProbeTable t;
    char text[1024];
    long n;
    long cr = 0;
    long i;

    n68_vprobe_table_init(&t);
    (void)n68_vprobe_add(&t, "Screen", "640x480 - 8-bit");
    (void)n68_vprobe_add(&t, "Raw 32-bit", "104.1 ms 8.7 MB/s 100%");
    (void)n68_vprobe_add(&t, "movem.l x8", "52.0 ms 17.4 MB/s 100%");

    n = n68_vprobe_render_text(&t, text, (long)sizeof text);
    CHECK(n > 0, "a table renders as text");
    for (i = 0; i < n; ++i) {
        if (text[i] == '\r') {
            ++cr;
        }
        CHECK(text[i] != '\n',
              "CR only - the rest of this guest writes CR and a mixed file "
              "invites a CRLF argument nobody needs to have");
    }
    CHECK(cr == 2, "three rows are two line breaks");
    CHECK(strncmp(text, "Screen", 6) == 0, "the first row leads");
    CHECK(strstr(text, "Screen           640x480") != NULL,
          "labels are padded into a column so the eye can run down it");

    /* Truncation never leaves half a row: at a capacity that holds the
       first row and not the second, the second is absent entirely rather
       than cut in half. */
    n = n68_vprobe_render_text(&t, text, 40);
    CHECK(n > 0 && text[n] == '\0', "a short buffer still terminates");
    CHECK(strchr(text, '\r') == NULL,
          "and stops at a row boundary rather than splitting one");
}

static void test_the_summary_the_console_gets(void)
{
    N68VProbeTable t;
    N68CmdResult res;
    char line[256];

    n68_vprobe_table_init(&t);
    (void)n68_vprobe_add(&t, "Screen", "640x480 - 8-bit");
    (void)n68_vprobe_add(&t, "Volume", "300 KB/frame");
    (void)n68_vprobe_add(&t, "Best raw", "movem.l x8 17.4 MB/s");

    n68_cmdresult_init(&res);
    n68_vprobe_summary(&t, &res);
    CHECK(res.ok == 1, "a measured table summarises as a success");
    CHECK_STR(res.key, "vprobe", "under the contract's output key");
    CHECK_STR(res.text, "640x480 - 8-bit", "row one is what was measured");
    CHECK_STR(res.state, "movem.l x8 17.4 MB/s",
              "row two is which method won - and it survives "
              "N68CmdResult's own field cap, which is tighter than a "
              "vprobe row");

    (void)n68_cmdresult_render_text(&res, line, (long)sizeof line);
    CHECK(strstr(line, "movem.l x8") != NULL,
          "so a person at the machine sees the headline");

    /* An empty table is a failure, not an empty success: a measurement
       command that answers ok with nothing in it is the one answer that
       cannot be acted on. */
    n68_vprobe_table_init(&t);
    n68_cmdresult_init(&res);
    n68_vprobe_summary(&t, &res);
    CHECK(res.ok == 0, "an empty table summarises as a failure");
    CHECK_STR(res.code, "vprobe-failed", "with a code that names it");

    /* A table with rows but no winner still says what it measured. */
    n68_vprobe_table_init(&t);
    (void)n68_vprobe_add(&t, "Screen", "640x480 - 8-bit");
    n68_cmdresult_init(&res);
    n68_vprobe_summary(&t, &res);
    CHECK(res.ok == 1 && res.state[0] == '\0',
          "a table with no Best raw row summarises to one row");
}

int main(void)
{
    test_geometry_accepts_the_180c();
    test_geometry_refuses_every_broken_field();
    test_bandwidth_formatting();
    test_scaling_bounds_a_slow_machine();
    test_prediction_is_linear_and_does_not_overflow();
    test_rows_are_sanitized_and_bounded();
    test_worst_case_reply_fits_the_stated_bound();
    test_a_reply_that_does_not_fit_is_no_reply();
    test_text_render_is_a_table();
    test_the_summary_the_console_gets();

    printf("%s: %d checks, %d failures\n",
           g_failures == 0 ? "PASS" : "FAIL", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
