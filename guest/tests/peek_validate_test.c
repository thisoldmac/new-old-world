/* Native test for the anchor reader's validation - the guard that
   keeps a foreign-pointer walk from bus-erroring. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src peek_validate_test.c \
          ../src/peek_validate.c -o peek_validate_test \
          && ./peek_validate_test

   Exercises the boundary and overflow cases, because those are exactly
   what a corrupt anchor produces and what must fail closed. */

#include <stdio.h>
#include <stdlib.h>

#include "peek_validate.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

int main(void)
{
    const unsigned long loc = 0x00100000UL;   /* 1 MB */
    const unsigned long size = 0x00080000UL;  /* 512 KB partition */

    /* In-bounds reads of various widths. */
    check(now_peek_range_in_partition(loc, 4, loc, size),
          "start of partition, 4 bytes");
    check(now_peek_range_in_partition(loc + size - 4, 4, loc, size),
          "last 4 bytes fit");
    check(now_peek_range_in_partition(loc + 0x1000, 156, loc, size),
          "a WindowRecord-sized read inside");

    /* Out of bounds, both ends. */
    check(!now_peek_range_in_partition(loc - 4, 4, loc, size),
          "before the partition");
    check(!now_peek_range_in_partition(loc + size - 2, 4, loc, size),
          "straddling the end fails");
    check(!now_peek_range_in_partition(loc + size, 4, loc, size),
          "at the end (exclusive) fails");

    /* Degenerate inputs fail closed. */
    check(!now_peek_range_in_partition(0, 4, loc, size), "null address");
    check(!now_peek_range_in_partition(loc, 0, loc, size), "zero length");
    check(!now_peek_range_in_partition(loc, 4, loc, 0), "zero partition");

    /* Overflow: a huge addr+len must not wrap past the end check. */
    check(!now_peek_range_in_partition(0xFFFFFFF0UL, 0x40, 0xFFFF0000UL,
                                       0x10000UL),
          "addr + len wraps -> refused");
    check(!now_peek_range_in_partition(loc, 0xFFFFFFF0UL, loc, size),
          "enormous length refused");

    /* Rect sanity. */
    check(now_peek_rect_sane(58, 64, 400, 576), "a normal window rect");
    check(now_peek_rect_sane(-20, -8, 340, 512),
          "a title bar above the menu bar is allowed");
    check(!now_peek_rect_sane(400, 64, 58, 576), "inverted top/bottom");
    check(!now_peek_rect_sane(58, 576, 400, 64), "inverted left/right");
    check(!now_peek_rect_sane(0, 0, 0, 0), "empty rect");
    check(!now_peek_rect_sane(0, 0, 9000, 9000), "absurdly large rect");
    check(!now_peek_rect_sane(-9000, -9000, 10, 10), "absurdly negative");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("peek_validate: all checks passed\n");
    return EXIT_SUCCESS;
}
