/*
 * test_shot.c - the Toolbox-free half of `screenshot`, under the host cc.
 *
 *   cc -Wall -Wextra -Werror -I ../src test_shot.c ../src/n68_shot.c \
 *      ../src/n68_cmdresult.c ../src/numfmt.c -o /tmp/test_shot
 *
 * (scripts/test-native runs it; that script's manifest is the gate, not
 * this comment.)
 *
 * WHAT IS WORTH TESTING HERE is what can be wrong QUIETLY. The capture
 * itself either produces a file on a Macintosh or does not, and a person
 * finds out immediately. These four do not announce themselves:
 *
 *   - band arithmetic that drops the remainder. 480 divides by 32 exactly,
 *     so the bug would be invisible on the one machine this targets and
 *     would silently crop the bottom of any other screen.
 *   - a name that collides. Two captures in one second, and the second
 *     overwrites the first - the failure being a MISSING screenshot, which
 *     reads as "I must not have pressed it".
 *   - a ratio computed the wrong way up. It would still be a plausible
 *     number, and it is the number slice two's viability is decided on.
 *   - a summary row that overflows its field. The wire renderer truncates
 *     rather than fails, so an over-long cost line loses its tail and
 *     nothing says so.
 */
#include "n68_shot.h"
#include "n68_cmdresult.h"

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

static void check_str(const char *got, const char *want, const char *what)
{
    if (strcmp(got, want) != 0) {
        printf("FAIL %s: got \"%s\" want \"%s\"\n", what, got, want);
        ++g_failures;
    }
}

/* ---- bands ---------------------------------------------------------------- */

static void test_bands_cover_the_whole_screen(void)
{
    static const long heights[] = { 480, 400, 342, 1, 33, 64, 870 };
    long h;
    unsigned long k;

    for (k = 0; k < sizeof heights / sizeof heights[0]; ++k) {
        long covered = 0;
        long n;
        long i;

        h = heights[k];
        n = n68_shot_band_count(h, kN68ShotBandRows);
        for (i = 0; i < n; ++i) {
            long top = n68_shot_band_top(h, kN68ShotBandRows, i);
            long rows = n68_shot_band_rows(h, kN68ShotBandRows, i);

            check(top == covered, "bands are contiguous");
            check(rows > 0 && rows <= kN68ShotBandRows, "band height is sane");
            covered += rows;
        }
        /* The one that matters: every row of the screen is in exactly one
         * band. A capture that drops the remainder produces a picture
         * that looks right on a 480-row display and is cropped on a
         * 342-row one. */
        check(covered == h, "the bands cover the whole screen");
    }
}

static void test_the_180c_splits_into_fifteen_full_bands(void)
{
    check(n68_shot_band_count(480, kN68ShotBandRows) == 15,
          "640x480 is fifteen 32-row bands");
    check(n68_shot_band_rows(480, kN68ShotBandRows, 14) == 32,
          "the last band of a 480-row screen is full");
    check(n68_shot_band_top(480, kN68ShotBandRows, 14) == 448,
          "the last band starts at row 448");
}

static void test_a_short_last_band(void)
{
    /* 400 rows: twelve full bands and a 16-row remainder. */
    check(n68_shot_band_count(400, kN68ShotBandRows) == 13, "13 bands");
    check(n68_shot_band_rows(400, kN68ShotBandRows, 12) == 16,
          "the last band is short, not clipped");
}

static void test_degenerate_band_inputs(void)
{
    check(n68_shot_band_count(0, kN68ShotBandRows) == 0, "no rows, no bands");
    check(n68_shot_band_count(480, 0) == 480, "rows <= 0 is treated as 1");
    check(n68_shot_band_rows(480, kN68ShotBandRows, -1) == 0,
          "a band index below zero is empty");
    check(n68_shot_band_rows(480, kN68ShotBandRows, 15) == 0,
          "a band index past the end is empty");
}

/* ---- the name ------------------------------------------------------------- */

static void test_the_contemporary_name(void)
{
    char name[kN68ShotNameCap];
    long n;

    n = n68_shot_name(name, (long)sizeof name, 2026, 7, 19, 22, 53, 1, 0, 0);
    check_str(name, "Screenshot 2026-07-19 22.53.01",
              "the PowerPC guest's name, byte for byte");
    check(n == 30, "30 characters, one under HFS's 31");
    check(n < kN68ShotNameCap, "it fits the buffer it is declared with");
}

static void test_the_name_pads_every_field(void)
{
    char name[kN68ShotNameCap];

    (void)n68_shot_name(name, (long)sizeof name, 2026, 1, 2, 3, 4, 5, 0, 0);
    check_str(name, "Screenshot 2026-01-02 03.04.05",
              "single digits are zero-padded");
}

static void test_a_second_shot_cannot_clobber_the_first(void)
{
    char first[kN68ShotNameCap];
    char second[kN68ShotNameCap];

    /* Same second, both attempts. If these ever agree, the second capture
     * overwrites the first and the person who took it sees one file. */
    (void)n68_shot_name(first, (long)sizeof first,
                        2026, 7, 19, 22, 53, 1, 1234567UL, 0);
    (void)n68_shot_name(second, (long)sizeof second,
                        2026, 7, 19, 22, 53, 1, 1234567UL, 1);
    check(strcmp(first, second) != 0,
          "the collision attempt produces a different name");
    check_str(second, "Screenshot 1234567", "the tick-stamped fallback");
}

static void test_the_name_refuses_a_buffer_it_would_overflow(void)
{
    char tiny[8];

    check(n68_shot_name(tiny, (long)sizeof tiny, 2026, 7, 19, 22, 53, 1, 0, 0)
              == 0,
          "a name that will not fit returns 0");
    check_str(tiny, "", "and leaves an empty string, not a half one");
}

/* ---- the ratio ------------------------------------------------------------ */

static void test_the_ratio_is_raw_over_packed(void)
{
    char r[16];

    (void)n68_shot_ratio(r, (long)sizeof r, 307200, 78769);
    check_str(r, "3.9:1", "300 KB packed to 77 KB is 3.9:1");

    (void)n68_shot_ratio(r, (long)sizeof r, 307200, 30720);
    check_str(r, "10.0:1", "a two-digit ratio");

    (void)n68_shot_ratio(r, (long)sizeof r, 300, 200);
    check_str(r, "1.5:1", "and it rounds to a tenth");
}

static void test_the_ratio_rounds_rather_than_truncates(void)
{
    char r[16];

    /* 100/57 = 1.754...; truncating to a tenth gives 1.7, rounding 1.8.
     * The distinction is the difference between a ratio a reader can
     * reproduce with a calculator and one they cannot. */
    (void)n68_shot_ratio(r, (long)sizeof r, 100, 57);
    check_str(r, "1.8:1", "1.754 rounds up");
}

static void test_incompressible_data_does_not_produce_a_strange_ratio(void)
{
    char r[16];

    /* PackBits expands data it cannot compress. That is a real outcome and
     * the bytes columns show it; this five-character field is not the
     * place to try to explain it. */
    (void)n68_shot_ratio(r, (long)sizeof r, 1000, 1200);
    check_str(r, "1.0:1", "an expanded picture reads 1.0:1");
    (void)n68_shot_ratio(r, (long)sizeof r, 1000, 0);
    check_str(r, "1.0:1", "and so does a zero-byte picture");
}

/* ---- the console line ----------------------------------------------------- */

static void test_the_default_line_saves_at_eight_bits(void)
{
    N68ShotArgs a;

    n68_shot_args_parse("", &a);
    check(a.depth == kN68ShotDepth && a.save == 1, "empty line: save at 8-bit");
    n68_shot_args_parse(NULL, &a);
    check(a.depth == kN68ShotDepth && a.save == 1, "NULL line is the same");
}

static void test_the_two_flags(void)
{
    N68ShotArgs a;

    n68_shot_args_parse("--no-save", &a);
    check(a.save == 0, "--no-save measures without writing");

    n68_shot_args_parse("--depth 8", &a);
    check(a.depth == 8 && a.save == 1, "--depth 8");

    n68_shot_args_parse("  --depth   16   --no-save  ", &a);
    check(a.depth == 16 && a.save == 0, "both, with generous whitespace");
}

static void test_a_typo_never_costs_a_capture(void)
{
    N68ShotArgs a;

    /* The contract's x-line says so in as many words: "Unrecognised flags
     * are ignored, never refused - a console typo must not cost a
     * capture." The screen will have moved by the time anyone retypes. */
    n68_shot_args_parse("--nosave --dept 8 rubbish", &a);
    check(a.save == 1 && a.depth == kN68ShotDepth,
          "unknown tokens are ignored, not refused");

    n68_shot_args_parse("--depth banana", &a);
    check(a.depth == kN68ShotDepth,
          "a non-numeric depth falls back rather than parsing to zero");
}

/* ---- the two rows --------------------------------------------------------- */

static void filled_stats(N68ShotStats *s, int saved)
{
    memset(s, 0, sizeof *s);
    s->width = 640;
    s->height = 480;
    s->depth = 8;
    s->raw_bytes = 307200;
    s->pict_bytes = 78769;
    s->read_ms = 214;
    s->encode_ms = 1832;
    s->write_ms = 96;
    if (saved) {
        strcpy(s->saved_name, "Screenshot 2026-07-19 22.53.01");
    }
}

static void test_the_summary_says_where_it_went(void)
{
    N68ShotStats s;
    N68CmdResult res;
    char text[512];

    filled_stats(&s, 1);
    n68_cmdresult_init(&res);
    n68_shot_summary(&s, &res);

    check(res.ok, "a capture is a success");
    check_str(res.key, "screenshot", "the output key the contract names");
    (void)n68_cmdresult_render_text(&res, text, (long)sizeof text);
    check_str(text,
              "Shot: 640x480x8, 78769 bytes, 3.9:1 -> "
              "Screenshot 2026-07-19 22.53.01\r"
              "Cost: read 214 ms, pack 1832 ms, write 96 ms",
              "the console's two lines");
}

static void test_the_summary_says_when_it_did_not_save(void)
{
    N68ShotStats s;
    N68CmdResult res;
    char text[512];

    filled_stats(&s, 0);
    n68_cmdresult_init(&res);
    n68_shot_summary(&s, &res);
    (void)n68_cmdresult_render_text(&res, text, (long)sizeof text);
    check(strstr(text, "(not saved)") != NULL,
          "--no-save says so rather than naming an empty file");
    check(strstr(text, "3.9:1") != NULL,
          "and still reports the ratio, which is the point of --no-save");
}

static void test_the_cost_row_fits_its_field(void)
{
    N68ShotStats s;
    N68CmdResult res;

    /* Five-digit milliseconds everywhere - a slow disk and a slower
     * encode. The cost row is the one field a caller cannot spill into
     * row one, so this is where a silent truncation would land. */
    filled_stats(&s, 1);
    s.read_ms = 99999;
    s.encode_ms = 99999;
    s.write_ms = 99999;
    n68_cmdresult_init(&res);
    n68_shot_summary(&s, &res);
    check_str(res.state, "read 99999 ms, pack 99999 ms, write 99999 ms",
              "the widest cost row this command can produce still fits");
}

static void test_the_row_one_field_fits_the_widest_shot(void)
{
    N68ShotStats s;
    N68CmdResult res;

    filled_stats(&s, 1);
    s.width = 1152;
    s.height = 870;
    s.raw_bytes = 1002240;
    s.pict_bytes = 999999;
    n68_cmdresult_init(&res);
    n68_shot_summary(&s, &res);
    check(strstr(res.text, "Screenshot 2026-07-19 22.53.01") != NULL,
          "even the widest geometry leaves room for the file name");
}

int main(void)
{
    test_bands_cover_the_whole_screen();
    test_the_180c_splits_into_fifteen_full_bands();
    test_a_short_last_band();
    test_degenerate_band_inputs();

    test_the_contemporary_name();
    test_the_name_pads_every_field();
    test_a_second_shot_cannot_clobber_the_first();
    test_the_name_refuses_a_buffer_it_would_overflow();

    test_the_ratio_is_raw_over_packed();
    test_the_ratio_rounds_rather_than_truncates();
    test_incompressible_data_does_not_produce_a_strange_ratio();

    test_the_default_line_saves_at_eight_bits();
    test_the_two_flags();
    test_a_typo_never_costs_a_capture();

    test_the_summary_says_where_it_went();
    test_the_summary_says_when_it_did_not_save();
    test_the_cost_row_fits_its_field();
    test_the_row_one_field_fits_the_widest_shot();

    if (g_failures != 0) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_shot: all checks passed\n");
    return 0;
}
