/*
 * test_packbits.c - the hand-rolled PackBits encoder, under the host cc.
 *
 * THE VECTOR IS THE TEST. Hand-rolling a compression format is only
 * defensible because there is an independent oracle for it, and there is:
 * Apple published a worked example of PackBits with both the unpacked and
 * the packed bytes. If this encoder agrees with that, it agrees with every
 * decoder that has ever read a PICT. A round trip against this file's own
 * unpacker would prove far less - "a test that constructs the message it
 * then parses tests one half twice" (AGENTS.md) - so the round trip below
 * is the supporting check and the vector is the real one.
 *
 * The other thing worth testing is the bound: PackBits EXPANDS
 * incompressible data, and a caller that sized a buffer with `len` instead
 * of n68_packbits_max(len) would overrun on exactly the input nobody tries
 * by hand.
 */
#include "n68_packbits.h"

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

static void dump(const char *label, const unsigned char *p, long n)
{
    long i;

    printf("  %s:", label);
    for (i = 0; i < n; ++i) {
        printf(" %02X", p[i]);
    }
    printf("\n");
}

/* Apple's published PackBits example (Technical Note / Inside Macintosh),
 * unpacked and packed, byte for byte. */
static const unsigned char kAppleUnpacked[] = {
    0xAA, 0xAA, 0xAA, 0x80, 0x00, 0x2A, 0xAA, 0xAA, 0xAA, 0xAA,
    0x80, 0x00, 0x2A, 0x22, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA, 0xAA,
    0xAA, 0xAA, 0xAA, 0xAA
};
static const unsigned char kApplePacked[] = {
    0xFE, 0xAA, 0x02, 0x80, 0x00, 0x2A, 0xFD, 0xAA, 0x03, 0x80,
    0x00, 0x2A, 0x22, 0xF7, 0xAA
};

static void test_apples_own_vector(void)
{
    unsigned char out[64];
    long n = n68_packbits_row(kAppleUnpacked, (long)sizeof kAppleUnpacked,
                              out, (long)sizeof out);

    check_long(n, (long)sizeof kApplePacked, "Apple's vector packs to 15");
    if (n == (long)sizeof kApplePacked
        && memcmp(out, kApplePacked, (size_t)n) != 0) {
        printf("FAIL Apple's vector, byte for byte\n");
        dump("got ", out, n);
        dump("want", kApplePacked, (long)sizeof kApplePacked);
        ++g_failures;
    }
}

static void test_the_vector_unpacks_back(void)
{
    unsigned char out[64];
    long n = n68_packbits_unrow(kApplePacked, (long)sizeof kApplePacked,
                                out, (long)sizeof out);

    check_long(n, (long)sizeof kAppleUnpacked, "and unpacks to 24");
    check(n == (long)sizeof kAppleUnpacked
          && memcmp(out, kAppleUnpacked, (size_t)n) == 0,
          "the unpacked bytes are Apple's");
}

/* Apple's vector contains no run of exactly two, so it does not pin the
 * one threshold this encoder actually chooses. Mutation found that gap:
 * `run >= 2` passed every other test in this file. This is the check that
 * fails when the threshold moves. */
static void test_a_run_of_exactly_two_stays_literal(void)
{
    /* The run has to be at the START. Mutation caught this twice: the
     * threshold appears in two places - the top-of-loop run check and the
     * literal scan's lookahead - and an input whose two-run sits in the
     * middle is decided by the lookahead alone, so it passes whatever the
     * top check says. Only a leading run reaches the branch under test. */
    static const unsigned char in[] = { 0x02, 0x02, 0x03, 0x04 };
    unsigned char out[16];
    long n = n68_packbits_row(in, (long)sizeof in, out, (long)sizeof out);

    /* One literal of four: 03 02 02 03 04. Taking the pair as a run
     * instead gives FF 02 01 03 04 - the same length here, and longer as
     * soon as more literal data follows it. */
    check_long(n, 5, "a leading run of two stays inside the literal");
    check(out[0] == 0x03 && out[1] == 0x02 && out[2] == 0x02
          && out[3] == 0x03 && out[4] == 0x04,
          "one four-byte literal, not a run followed by a short literal");
}

static void test_a_flat_row_packs_hard(void)
{
    unsigned char row[640];
    unsigned char out[1024];
    long n;

    memset(row, 0x1D, sizeof row);
    n = n68_packbits_row(row, (long)sizeof row, out, (long)sizeof out);
    /* 640 bytes is five maximal 128-byte runs, two bytes each. This is the
     * shape a classic Mac desktop is mostly made of, and the reason the
     * 180c's screen packs 4.7:1. */
    check_long(n, 10, "a flat 640-byte row is ten bytes");
}

static void test_packbits_can_grow_and_the_bound_says_so(void)
{
    unsigned char row[640];
    unsigned char out[1024];
    long i, n;

    /* Incompressible: no byte equals its neighbour. */
    for (i = 0; i < (long)sizeof row; ++i) {
        row[i] = (unsigned char)((i * 7) & 0xFF);
    }
    n = n68_packbits_row(row, (long)sizeof row, out, (long)sizeof out);
    check(n > (long)sizeof row, "noise packs LARGER than it started");
    check(n <= n68_packbits_max((long)sizeof row),
          "and never past the published bound");
    check_long(n68_packbits_max(640), 645, "the bound for a 640-byte row");
    check_long(n68_packbits_max(128), 129, "exactly one control byte");
    check_long(n68_packbits_max(129), 131, "and a second for the remainder");
}

static void test_a_destination_too_small_writes_nothing(void)
{
    unsigned char row[640];
    unsigned char out[640];       /* `len`, not max(len) - the caller's bug */
    long n;

    memset(row, 0, sizeof row);
    out[0] = 0xEE;
    n = n68_packbits_row(row, (long)sizeof row, out, (long)sizeof out);
    check_long(n, -1, "a buffer sized with len is refused");
    check(out[0] == 0xEE, "and nothing is written into it");
}

static void test_round_trip_over_many_shapes(void)
{
    unsigned char row[640];
    unsigned char packed[1024];
    unsigned char back[640];
    long shape, i, n, m;

    for (shape = 0; shape < 6; ++shape) {
        for (i = 0; i < (long)sizeof row; ++i) {
            switch (shape) {
            case 0: row[i] = 0; break;
            case 1: row[i] = (unsigned char)i; break;
            case 2: row[i] = (unsigned char)(i / 3); break;
            case 3: row[i] = (unsigned char)((i % 2) ? 0xFF : 0x00); break;
            case 4: row[i] = (unsigned char)((i < 320) ? 0x40 : (i * 11)); break;
            default: row[i] = (unsigned char)((i * i) & 0xFF); break;
            }
        }
        n = n68_packbits_row(row, (long)sizeof row, packed,
                             (long)sizeof packed);
        check(n > 0, "every shape packs");
        m = n68_packbits_unrow(packed, n, back, (long)sizeof back);
        check_long(m, (long)sizeof row, "and unpacks to its own length");
        check(memcmp(row, back, sizeof row) == 0,
              "and to its own bytes - no shape is lossy");
    }
}

static void test_edges(void)
{
    unsigned char out[8];

    check_long(n68_packbits_row((const unsigned char *)"", 0, out,
                                (long)sizeof out), 0, "nothing packs to nothing");
    check_long(n68_packbits_row(NULL, 4, out, (long)sizeof out), -1,
               "no source, no output");
    {
        /* One byte: a literal of one, never a run. */
        unsigned char one = 0x5A;
        long n = n68_packbits_row(&one, 1, out, (long)sizeof out);

        check_long(n, 2, "a single byte is a two-byte literal");
        check(out[0] == 0x00 && out[1] == 0x5A, "control 0, then the byte");
    }
}

int main(void)
{
    test_apples_own_vector();
    test_the_vector_unpacks_back();
    test_a_run_of_exactly_two_stays_literal();
    test_a_flat_row_packs_hard();
    test_packbits_can_grow_and_the_bound_says_so();
    test_a_destination_too_small_writes_nothing();
    test_round_trip_over_many_shapes();
    test_edges();

    if (g_failures != 0) {
        printf("%d failure(s)\n", g_failures);
        return 1;
    }
    printf("test_packbits: all checks passed\n");
    return 0;
}
