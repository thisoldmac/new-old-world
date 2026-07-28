/*
 * test_crc32.c - native test for n68_crc32.c.
 *
 *   cc -Wall -Wextra -Werror -I ../src test_crc32.c ../src/n68_crc32.c -o /tmp/t
 *
 * (scripts/test-native runs this; the line above is for editing one file.)
 *
 * WHAT THIS IS ACTUALLY FOR. The guest computes a CRC over the bytes it
 * writes; the HOST computes one over the bytes it sends, with zlib. If
 * the two implementations disagree by so much as a convention, every
 * transfer reports `corrupt` and deletes a file that arrived perfectly -
 * and the failure would point at the file code, which would be innocent.
 * So this pins the published check values rather than testing
 * n68_crc32.c against itself, which is the trap AGENTS.md names: a test
 * that constructs the message it then parses tests one half twice.
 *
 * The composition case is the one with teeth on a wire. Bytes arrive in
 * whatever runs MacTCP happens to hand over - never the same split
 * twice - so "CRC of the whole" and "CRC accumulated across N splits"
 * must be the same number for EVERY split, not for the tidy ones.
 */

#include "n68_crc32.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check_u32(const char *what, unsigned long got, unsigned long want)
{
    if (got != want) {
        printf("FAIL %s: got %08lX, wanted %08lX\n", what, got, want);
        ++failures;
    }
}

/* The two values every CRC-32 implementation publishes. 0xCBF43926 for
 * "123456789" is THE check value in the CRC catalogue (CRC-32/ISO-HDLC);
 * the empty input is 0 by the seed-and-finish convention, and getting
 * that one wrong is how an off-by-one in the un-finish/finish masking
 * shows up. */
static void test_published_check_values(void)
{
    check_u32("\"123456789\"",
              now68k_crc32(0, "123456789", 9), 0xCBF43926UL);
    check_u32("empty input", now68k_crc32(0, "", 0), 0UL);
    check_u32("empty input, NULL pointer",
              now68k_crc32(0, NULL, 0), 0UL);
    /* One more independent vector, so a table built wrong in a way that
     * happens to survive "123456789" still fails: zlib's crc32 of "a". */
    check_u32("\"a\"", now68k_crc32(0, "a", 1), 0xE8B7BE43UL);
    /* And a run long enough to exercise every table row rather than the
     * handful of entries a 9-byte input touches. */
    {
        unsigned char all[256];
        int i;

        for (i = 0; i < 256; ++i) {
            all[i] = (unsigned char)i;
        }
        check_u32("0x00..0xFF", now68k_crc32(0, all, 256), 0x29058C73UL);
    }
}

/* The property the wire depends on: any split, same answer. */
static void test_composition_across_every_split(void)
{
    static const char text[] =
        "The quick brown fox jumps over the lazy dog, repeatedly, at "
        "length, so that this buffer is longer than any one split.";
    long n = (long)strlen(text);
    unsigned long whole = now68k_crc32(0, text, n);
    long cut;

    for (cut = 0; cut <= n; ++cut) {
        unsigned long c = now68k_crc32(0, text, cut);

        c = now68k_crc32(c, text + cut, n - cut);
        if (c != whole) {
            printf("FAIL composition at cut %ld: got %08lX, wanted %08lX\n",
                   cut, c, whole);
            ++failures;
            return;   /* one report is enough; they would all be the same */
        }
    }

    /* Byte at a time is the pathological split, and the one a slow link
     * actually produces when MacTCP dribbles. */
    {
        unsigned long c = 0;
        long i;

        for (i = 0; i < n; ++i) {
            c = now68k_crc32(c, text + i, 1);
        }
        check_u32("one byte at a time", c, whole);
    }
}

/* A zero-length run in the middle must not disturb the accumulator. The
 * receive path calls this on every flush, and a flush of an empty batch
 * buffer is an ordinary event at end-of-file. */
static void test_empty_runs_are_transparent(void)
{
    unsigned long a = now68k_crc32(0, "abcdef", 6);
    unsigned long b;

    b = now68k_crc32(0, "abc", 3);
    b = now68k_crc32(b, "", 0);
    b = now68k_crc32(b, NULL, 0);
    b = now68k_crc32(b, "def", 3);
    check_u32("empty runs are transparent", b, a);
}

/* A negative length is a caller bug, but it must not read memory. */
static void test_negative_length_is_a_no_op(void)
{
    check_u32("negative length", now68k_crc32(0x12345678UL, "abc", -1),
              0x12345678UL);
}

int main(void)
{
    test_published_check_values();
    test_composition_across_every_split();
    test_empty_runs_are_transparent();
    test_negative_length_is_a_no_op();

    if (failures != 0) {
        printf("%d failure(s)\n", failures);
        return 1;
    }
    printf("all crc32 checks passed\n");
    return 0;
}
