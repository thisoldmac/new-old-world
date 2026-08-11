#include "files_capacity.h"

#include <stdio.h>

static int failures;

static void check(long actual, long expected, const char *message)
{
    if (actual != expected) {
        fprintf(stderr, "FAIL: %s (got %ld, wanted %ld)\n",
                message, actual, expected);
        ++failures;
    }
}

int main(void)
{
    check(now_files_volume_capacity(1000UL, 4096UL), 4096000L,
          "ordinary volume capacity is exact");
    check(now_files_volume_capacity(0UL, 4096UL), 0L,
          "zero free blocks means zero bytes");
    check(now_files_volume_capacity(0xFFFFFFFFUL, 4096UL), 2147483647L,
          "capacity above the Classic signed-long range saturates");
    check(now_files_volume_capacity(1UL, 0x80000000UL), 2147483647L,
          "one oversized allocation block also saturates");

    if (failures != 0) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("all file-capacity checks passed");
    return 0;
}
