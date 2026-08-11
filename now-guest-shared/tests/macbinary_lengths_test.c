#include "macbinary_lengths.h"

#include <stdio.h>
#include <string.h>

static int failures;

static void check(int condition, const char *message)
{
    if (!condition) {
        fprintf(stderr, "FAIL: %s\n", message);
        ++failures;
    }
}

static void put_u32(unsigned char *p, unsigned long value)
{
    p[0] = (unsigned char)(value >> 24);
    p[1] = (unsigned char)(value >> 16);
    p[2] = (unsigned char)(value >> 8);
    p[3] = (unsigned char)value;
}

int main(void)
{
    unsigned char header[128];
    long data_length = -1;
    long resource_length = -1;

    memset(header, 0, sizeof header);
    put_u32(header + 83, 129);
    put_u32(header + 87, 1);
    check(now_macbinary_fork_lengths(header, 512, &data_length,
                                     &resource_length),
          "fork lengths that fit the envelope are accepted");
    check(data_length == 129 && resource_length == 1,
          "accepted fork lengths are decoded exactly");

    put_u32(header + 83, 0x80000000UL);
    check(!now_macbinary_fork_lengths(header, 512, &data_length,
                                      &resource_length),
          "a fork outside the Classic signed-long range is refused");

    put_u32(header + 83, 0x7FFFFFFFUL);
    check(!now_macbinary_fork_lengths(header, 512, &data_length,
                                      &resource_length),
          "a fork larger than the offered envelope is refused before padding");

    put_u32(header + 83, 257);
    put_u32(header + 87, 1);
    check(!now_macbinary_fork_lengths(header, 512, &data_length,
                                      &resource_length),
          "the two padded forks must fit together");

    if (failures != 0) {
        fprintf(stderr, "%d failure(s)\n", failures);
        return 1;
    }
    puts("all MacBinary length checks passed");
    return 0;
}
