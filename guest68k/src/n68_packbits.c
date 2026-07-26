/*
 * n68_packbits.c - implementation of n68_packbits.h. Read that header
 * first: it carries why this guest owns an encoder at all when QuickDraw
 * already packs, and that the output can be LARGER than the input.
 *
 * STATIC BUDGET: none. No BSS, no allocation.
 */
#include "n68_packbits.h"

#include <stddef.h>

enum {
    kMaxRun = 128,      /* the longest run or literal a control byte spans */
    kNoOp   = 128       /* reserved; never emitted */
};

long n68_packbits_max(long len)
{
    if (len <= 0) {
        return 0;
    }
    return len + (len + kMaxRun - 1) / kMaxRun;
}

long n68_packbits_row(const unsigned char *src, long len,
                      unsigned char *dst, long cap)
{
    long in = 0;
    long out = 0;

    if (src == NULL || dst == NULL || len < 0 || cap < 0) {
        return -1;
    }
    if (len == 0) {
        return 0;
    }
    if (cap < n68_packbits_max(len)) {
        return -1;
    }

    while (in < len) {
        long run = 1;

        /* How far the byte at `in` repeats, capped at what one control
         * byte can say. */
        while (in + run < len && src[in + run] == src[in] && run < kMaxRun) {
            ++run;
        }

        if (run >= 3) {
            /* Three is the threshold, and it is an EFFICIENCY choice, not
             * a correctness one: a decoder reads either spelling, and
             * Apple's published vector happens to contain no run of
             * exactly two, so it cannot tell them apart. (Found by
             * mutation - changing this to `>= 2` left every test green,
             * which is why test_packbits.c now pins the two-byte case
             * directly.)
             *
             * Two breaks even on its own (two bytes out for two in) and
             * then costs a control byte for the literal it interrupted,
             * so it loses on any row where short runs sit inside literal
             * data - which is what a dithered screen is. Three is what
             * every reference encoder uses, for this reason. */
            dst[out++] = (unsigned char)(257 - run);
            dst[out++] = src[in];
            in += run;
            continue;
        }

        /* A literal run: bytes up to the next run of three or more. */
        {
            long start = in;
            long n = 0;

            while (in < len && n < kMaxRun) {
                long ahead = 1;

                while (in + ahead < len && src[in + ahead] == src[in]
                       && ahead < 3) {
                    ++ahead;
                }
                if (ahead >= 3) {
                    break;      /* the run path takes it from here */
                }
                ++in;
                ++n;
            }
            dst[out++] = (unsigned char)(n - 1);
            for (; start < in; ++start) {
                dst[out++] = src[start];
            }
        }
    }
    return out;
}

long n68_packbits_unrow(const unsigned char *src, long len,
                        unsigned char *dst, long cap)
{
    long in = 0;
    long out = 0;

    if (src == NULL || dst == NULL || len < 0 || cap < 0) {
        return -1;
    }
    while (in < len) {
        int control = src[in++];
        long n;

        if (control == kNoOp) {
            continue;
        }
        if (control < kNoOp) {
            n = control + 1;
            if (in + n > len || out + n > cap) {
                return -1;
            }
            while (n-- > 0) {
                dst[out++] = src[in++];
            }
        } else {
            n = 257 - control;
            if (in >= len || out + n > cap) {
                return -1;
            }
            {
                unsigned char b = src[in++];

                while (n-- > 0) {
                    dst[out++] = b;
                }
            }
        }
    }
    return out;
}
