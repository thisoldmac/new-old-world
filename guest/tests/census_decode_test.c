/* Native test for the census decoder - runs on the host:
   cc -Wall -Wextra -Werror -I ../src census_decode_test.c \
      ../src/census_decode.c -o census_decode_test && ./census_decode_test
   Pure C; the readings are provable without the machine. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "census_decode.h"

/* A small fake selector + bit table, standing in for census_selectors.h
   (which needs Carbon). The decoder never sees the real one - it takes
   the table as a parameter, which is exactly what makes it testable. */
enum { kHW = 0x68647772UL };        /* 'hdwr' */
enum { kSV = 0x73797376UL };        /* 'sysv' */

static const NowCensusAttrBit kBits[] = {
    { kHW, 3, "ASC" },
    { kHW, 4, "SCC" },
    { kHW, 7, "SCSI" },
    { kHW, 19, "soft power off" },
};
#define NBITS ((int)(sizeof kBits / sizeof kBits[0]))

static void test_version_bcd(void)
{
    char out[64];
    /* gestaltSystemVersion low word 0x0921 -> 9.2.1 */
    census_summarize(kCensusSelVersion, kSV, 0x0921, kBits, NBITS,
                     out, sizeof out);
    assert(strcmp(out, "version 9.2.1") == 0);
    census_summarize(kCensusSelVersion, kSV, 0x0910, kBits, NBITS,
                     out, sizeof out);
    assert(strcmp(out, "version 9.1") == 0);   /* trailing .0 dropped */
}

static void test_version_numversion(void)
{
    char out[64];
    /* NumVersion, major in the high byte: 0x06508000 -> 6.5 (QuickTime) */
    census_summarize(kCensusSelVersion, kSV, 0x06508000UL, kBits, NBITS,
                     out, sizeof out);
    assert(strcmp(out, "version 6.5") == 0);
    /* CarbonVersion BCD low word 0x0160 -> 1.6 */
    census_summarize(kCensusSelVersion, kSV, 0x0160UL, kBits, NBITS,
                     out, sizeof out);
    assert(strcmp(out, "version 1.6") == 0);
}

static void test_version_16_16_split(void)
{
    char out[64];
    /* ATSUVersion 393216 = 0x00060000 -> 6.0, NOT the bare number 393216 */
    census_summarize(kCensusSelVersion, kSV, 393216UL, kBits, NBITS,
                     out, sizeof out);
    assert(strcmp(out, "version 6.0") == 0);
}

static void test_attr_summary(void)
{
    char out[80];
    unsigned long raw = (1UL << 3) | (1UL << 4) | (1UL << 7) | (1UL << 19);
    census_summarize(kCensusSelAttr, kHW, raw, kBits, NBITS, out, sizeof out);
    /* first two named, then a count of the rest */
    assert(strcmp(out, "ASC, SCC + 2 more") == 0);
}

static void test_attr_summary_all_known_short(void)
{
    char out[80];
    unsigned long raw = (1UL << 3) | (1UL << 4);
    census_summarize(kCensusSelAttr, kHW, raw, kBits, NBITS, out, sizeof out);
    assert(strcmp(out, "ASC, SCC") == 0);   /* no "+ more" when it fits */
}

static void test_attr_unknown_bit_kept(void)
{
    char out[80];
    unsigned long raw = (1UL << 3) | (1UL << 11);   /* 11 not in table */
    census_summarize(kCensusSelAttr, kHW, raw, kBits, NBITS, out, sizeof out);
    /* the unknown bit still counts - nothing hidden */
    assert(strcmp(out, "ASC, bit 11") == 0);
}

static void test_size_and_hz(void)
{
    char out[64];
    census_summarize(kCensusSelSize, kSV, 64UL * 1024 * 1024, kBits, NBITS,
                     out, sizeof out);
    assert(strcmp(out, "64 MB") == 0);
    census_summarize(kCensusSelHz, kSV, 116522667UL, kBits, NBITS,
                     out, sizeof out);
    assert(strcmp(out, "117 MHz") == 0);
}

static void test_detail_attr_lists_bits(void)
{
    NowCensusSelector sel = { kHW, "HardwareAttr", kCensusSelAttr,
                              "hardware attributes" };
    char lines[16][80];
    unsigned long raw = (1UL << 3) | (1UL << 7) | (1UL << 11);
    int n = census_detail(&sel, raw, kBits, NBITS, (char *)lines, 16, 80);
    int i, saw_asc = 0, saw_scsi = 0, saw_cand = 0, saw_summary = 0;

    assert(n >= 5);
    assert(strstr(lines[0], "'hdwr'") != NULL);
    assert(strstr(lines[0], "HardwareAttr") != NULL);
    assert(strstr(lines[1], "hardware attributes") != NULL);   /* comment */
    assert(strstr(lines[2], "Raw  $00000888") != NULL);   /* 8|128|2048 */
    for (i = 3; i < n; i++) {
        if (strstr(lines[i], "ASC")) saw_asc = 1;
        if (strstr(lines[i], "SCSI")) saw_scsi = 1;
        /* the per-bit line for the unknown bit, distinct from the summary */
        if (strstr(lines[i], "bit 11") && strstr(lines[i], "candidate")) {
            saw_cand = 1;
        }
        if (strstr(lines[i], "unrecognized - kept")) saw_summary = 1;
    }
    assert(saw_asc && saw_scsi);
    assert(saw_cand);          /* bit 11 surfaced by number, not dropped */
    assert(saw_summary);
}

static void test_detail_version_shows_reading(void)
{
    NowCensusSelector sel = { kSV, "SystemVersion", kCensusSelVersion,
                              "system version" };
    char lines[16][80];
    int n = census_detail(&sel, 0x0921, kBits, NBITS, (char *)lines, 16, 80);
    int i, saw = 0;

    for (i = 0; i < n; i++) {
        if (strstr(lines[i], "version 9.2.1")) saw = 1;
    }
    assert(saw);
}

int main(void)
{
    test_version_bcd();
    test_version_numversion();
    test_version_16_16_split();
    test_attr_summary();
    test_attr_summary_all_known_short();
    test_attr_unknown_bit_kept();
    test_size_and_hz();
    test_detail_attr_lists_bits();
    test_detail_version_shows_reading();
    printf("census_decode_test: ok\n");
    return 0;
}
