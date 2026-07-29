/* Host-side test for the capture diagnostic's renderer
 * (src/screenshots/n68_shotdiag.c).
 *
 * WHAT THIS DOES NOT TEST, said first because the whole point of the
 * diagnostic is to be believed on a machine nobody here can reach: it
 * proves nothing about the PowerBook 180c, nothing about StripAddress,
 * nothing about the MMU, and nothing about what the walk reads. Those are
 * Toolbox calls made inside shotstage68.c and they are unreachable from a
 * host cc. What this file gates is the part that can silently LIE about
 * them:
 *
 *   - the verdict. Four outcomes, and three of them are not "fail": bytes
 *     that match, bytes that differ, a screen that moved between the two
 *     looks, and no band to compare against. Collapsing any of those into
 *     another is how a trip to the other room gets wasted, so each is
 *     pinned by name.
 *   - the hex renderer's WIDTH. Sixteen bytes render to exactly 47
 *     characters and a row value holds 48 including its NUL, so the format
 *     fits with nothing to spare. If either number moves, n68_cmdrows_add
 *     would truncate silently and a short line would read as a value
 *     rather than as a cut - so the two are pinned against each other here
 *     rather than left to agree by coincidence.
 *   - truncation ending on a byte boundary, for the same reason.
 *   - every fact reaching the table. A field sampled on the guest and then
 *     dropped by the renderer is worse than one never sampled: it reads as
 *     an answer.
 *
 * The parser is deliberately dumb - substring searches over the rows, not
 * a reader that shares code with the thing under test (AGENTS.md).
 */

#include "n68_shotdiag.h"

#include <stdio.h>
#include <string.h>

static int g_failures = 0;
static int g_checks = 0;

#define CHECK(cond, msg) do { \
        g_checks++; \
        if (!(cond)) { \
            printf("  FAIL %s (%s:%d)\n", (msg), __FILE__, __LINE__); \
            g_failures++; \
        } \
    } while (0)

/* The value of the first row with this label, or NULL. */
static const char *value_of(const N68CmdRows *rows, const char *label)
{
    int i;

    for (i = 0; i < rows->count; ++i) {
        if (strcmp(rows->rows[i].label, label) == 0) {
            return rows->rows[i].value;
        }
    }
    return NULL;
}

static int has_row(const N68CmdRows *rows, const char *label,
                   const char *value)
{
    const char *got = value_of(rows, label);

    return got != NULL && strcmp(got, value) == 0;
}

/* A diagnostic that found nothing wrong: base above 16 MB, StripAddress
 * leaving it alone, 32-bit addressing, and all three samples equal. */
static void fill_clean(N68ShotDiag *d)
{
    int i;

    n68_shotdiag_init(d);
    d->base = 0xFC080000UL;
    d->stripped = 0xFC080000UL;
    d->mmu32 = 1;
    d->reach = kN68ShotDiagReachDirect;
    d->width = 640;
    d->height = 480;
    d->depth = 8;
    d->fb_row_bytes = 640;
    d->row_bytes = 640;
    d->staged_bytes = 65432;
    d->walk_ok = 1;
    d->pair_ok = 1;
    for (i = 0; i < kN68ShotDiagSampleBytes; ++i) {
        d->walk[i] = (unsigned char)(0xF0 + i);
        d->walk_again[i] = (unsigned char)(0xF0 + i);
        d->blit[i] = (unsigned char)(0xF0 + i);
    }
}

static void test_hex_is_exactly_a_row_wide(void)
{
    unsigned char bytes[kN68ShotDiagSampleBytes];
    char ample[4 * kN68ShotDiagSampleBytes + 8];
    char row[kN68CmdRowValueCap];
    long n_ample;
    long n_row;
    int i;

    printf("hex_is_exactly_a_row_wide\n");
    for (i = 0; i < kN68ShotDiagSampleBytes; ++i) {
        bytes[i] = 0xFF;
    }
    n_ample = n68_shotdiag_hex(bytes, (long)kN68ShotDiagSampleBytes,
                               ample, (long)sizeof ample);
    n_row = n68_shotdiag_hex(bytes, (long)kN68ShotDiagSampleBytes,
                             row, (long)sizeof row);

    CHECK(n_ample == 3 * (long)kN68ShotDiagSampleBytes - 1,
          "two digits and a separator per byte, less the leading one");
    /* THE ONE THAT MATTERS, and the one a naive length check misses: a
     * row-sized buffer must render the SAME string as an ample one. A
     * renderer that truncates produces a shorter line that is
     * indistinguishable from a shorter sample, which is a lie about the
     * screen told to somebody standing in another room. */
    CHECK(n_row == n_ample && strcmp(row, ample) == 0,
          "a row-sized buffer renders the whole sample, not a prefix");
    CHECK(strlen(row) == (size_t)n_row,
          "and the string agrees with the return");
    CHECK(row[2] == ' ' && row[5] == ' ', "space-separated pairs");
}

static void test_a_short_buffer_cuts_on_a_byte_boundary(void)
{
    unsigned char bytes[kN68ShotDiagSampleBytes];
    char out[10];
    long n;
    int i;

    printf("a_short_buffer_cuts_on_a_byte_boundary\n");
    for (i = 0; i < kN68ShotDiagSampleBytes; ++i) {
        bytes[i] = (unsigned char)(0xA0 + i);
    }
    n = n68_shotdiag_hex(bytes, (long)kN68ShotDiagSampleBytes,
                         out, (long)sizeof out);
    /* "A0 A1 A2" is 8 characters and the ninth would be a lone space. */
    CHECK(n == 8, "stops at the last WHOLE byte that fits");
    CHECK(strcmp(out, "A0 A1 A2") == 0, "and does not end mid-byte");
    CHECK(out[n] == '\0', "NUL-terminated inside the buffer");
}

static void test_matching_samples_clear_the_base(void)
{
    N68ShotDiag d;
    N68CmdRows rows;
    const char *verdict;

    printf("matching_samples_clear_the_base\n");
    fill_clean(&d);
    n68_cmdrows_init(&rows);
    n68_shotdiag_rows(&d, &rows);

    verdict = value_of(&rows, "Verdict");
    CHECK(verdict != NULL, "there is a verdict row");
    CHECK(verdict != NULL && strstr(verdict, "identical") != NULL,
          "identical samples say so");
    CHECK(verdict != NULL && strstr(verdict, "DIFFERS") == NULL,
          "and do not also say they differ");
    CHECK(has_row(&rows, "Base", "0xFC080000"), "the base is reported");
    CHECK(has_row(&rows, "StripAddress", "0xFC080000"),
          "StripAddress is reported separately");
    CHECK(has_row(&rows, "Addressing", "32-bit"), "the MMU mode is reported");
    CHECK(has_row(&rows, "Raw read", "direct - no switch needed"),
          "and what the walk did about it is a separate row");
    CHECK(has_row(&rows, "Screen", "640x480 8-bit"), "geometry is reported");
    CHECK(has_row(&rows, "Bytes", "stride 640, row 640"),
          "the screen's stride and the promised row are BOTH reported");
    CHECK(value_of(&rows, "Walk row 0") != NULL, "the walk sample is a row");
    CHECK(value_of(&rows, "Blit row 0") != NULL, "the blit sample is a row");
    CHECK(has_row(&rows, "Capture", "65432 bytes staged"),
          "what the staging actually wrote is reported");
    CHECK(rows.count <= kN68CmdRowsMax, "the table fits");
}

static void test_a_differing_byte_is_named(void)
{
    N68ShotDiag d;
    N68CmdRows rows;
    const char *verdict;

    printf("a_differing_byte_is_named\n");
    fill_clean(&d);
    d.blit[3] ^= 0xFF;
    n68_cmdrows_init(&rows);
    n68_shotdiag_rows(&d, &rows);

    verdict = value_of(&rows, "Verdict");
    CHECK(verdict != NULL && strstr(verdict, "DIFFERS") != NULL,
          "a disagreement is loud");
    /* The BYTE, not just the fact. Byte 3 of a 640-byte row is the first
     * pixel of the second longword, and knowing which one narrows the next
     * question from "the walk" to "the walk's alignment". */
    CHECK(verdict != NULL && strstr(verdict, "3") != NULL,
          "and names which byte");
}

static void test_a_moving_screen_does_not_read_as_a_pass(void)
{
    N68ShotDiag d;
    N68CmdRows rows;
    const char *verdict;

    printf("a_moving_screen_does_not_read_as_a_pass\n");
    fill_clean(&d);
    /* The walk and the blit agree NOW, but row 0 changed between the
     * capture and the comparison - so this run says nothing about the
     * bytes that actually went out, and must not read as though it did. */
    d.walk[0] ^= 0xFF;
    n68_cmdrows_init(&rows);
    n68_shotdiag_rows(&d, &rows);

    verdict = value_of(&rows, "Verdict");
    CHECK(verdict != NULL && strstr(verdict, "moved") != NULL,
          "a screen that moved is said out loud");
    CHECK(verdict != NULL && strstr(verdict, "identical -") == NULL,
          "and is not the clean verdict");
}

static void test_no_band_is_not_a_pass_either(void)
{
    N68ShotDiag d;
    N68CmdRows rows;
    const char *verdict;

    printf("no_band_is_not_a_pass_either\n");
    fill_clean(&d);
    d.pair_ok = 0;
    n68_cmdrows_init(&rows);
    n68_shotdiag_rows(&d, &rows);

    verdict = value_of(&rows, "Verdict");
    CHECK(verdict != NULL && strstr(verdict, "not compared") != NULL,
          "no second opinion says so");
    CHECK(verdict != NULL && strstr(verdict, "identical") == NULL,
          "and never reads as a match");
    CHECK(has_row(&rows, "Blit row 0", "no offscreen band"),
          "the missing sample is named where it would have been");
}

static void test_a_stripped_base_survives_to_the_table(void)
{
    N68ShotDiag d;
    N68CmdRows rows;

    printf("a_stripped_base_survives_to_the_table\n");
    fill_clean(&d);
    /* The shape the whole diagnostic existed to catch, and the shape a
     * PowerBook with a dead PRAM battery boots into every time: a
     * framebuffer above 16 MB, and a machine that has decided the top byte
     * is not an address. 0xFC080000 truncates to 0x00080000, main RAM. */
    d.stripped = 0x00080000UL;
    d.mmu32 = 0;
    d.reach = kN68ShotDiagReachSwitch;
    n68_cmdrows_init(&rows);
    n68_shotdiag_rows(&d, &rows);

    CHECK(has_row(&rows, "Base", "0xFC080000"), "the base is unchanged");
    CHECK(has_row(&rows, "StripAddress", "0x00080000"),
          "and the stripped address is reported as it came back");
    /* NO LONGER "(!)". It is the expected state of these machines, and the
     * next row is what says whether it mattered. A reader who saw the old
     * exclamation mark beside a capture that is now correct would go
     * looking for a bug that had already been fixed. */
    CHECK(has_row(&rows, "Addressing", "24-bit"),
          "24-bit addressing is reported as a fact, not an alarm");
    CHECK(has_row(&rows, "Raw read", "SwapMMUMode to 32-bit"),
          "and the walk says it switched to reach the screen");
}

/* A Mac that cannot switch at all. There is nothing honest to send from
 * here, and the table has to say so rather than leave a reader to infer it
 * from a base and a mode. */
static void test_an_unreachable_screen_says_so(void)
{
    N68ShotDiag d;
    N68CmdRows rows;

    printf("an_unreachable_screen_says_so\n");
    fill_clean(&d);
    d.stripped = 0x00080000UL;
    d.mmu32 = 0;
    d.reach = kN68ShotDiagReachRefused;
    n68_cmdrows_init(&rows);
    n68_shotdiag_rows(&d, &rows);

    CHECK(has_row(&rows, "Raw read", "REFUSED - unreachable"),
          "an unreachable framebuffer is named as such");
}

static void test_a_walk_that_never_ran_says_so(void)
{
    N68ShotDiag d;
    N68CmdRows rows;
    const char *verdict;

    printf("a_walk_that_never_ran_says_so\n");
    n68_shotdiag_init(&d);
    n68_cmdrows_init(&rows);
    n68_shotdiag_rows(&d, &rows);

    verdict = value_of(&rows, "Verdict");
    CHECK(verdict != NULL && strstr(verdict, "never ran") != NULL,
          "an unsampled run is not a clean one");
    CHECK(has_row(&rows, "Walk row 0", "not sampled"),
          "and the sample rows say they are empty");
}

int main(void)
{
    printf("test_shotdiag\n");
    test_hex_is_exactly_a_row_wide();
    test_a_short_buffer_cuts_on_a_byte_boundary();
    test_matching_samples_clear_the_base();
    test_a_differing_byte_is_named();
    test_a_moving_screen_does_not_read_as_a_pass();
    test_no_band_is_not_a_pass_either();
    test_a_stripped_base_survives_to_the_table();
    test_an_unreachable_screen_says_so();
    test_a_walk_that_never_ran_says_so();

    printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
