/* n68_crc32.c - implementation of n68_crc32.h. */

#include "n68_crc32.h"

/* 0xEDB88320 is the reflected form of the IEEE polynomial; the whole
 * algorithm below is the reflected one, which is what zlib computes and
 * therefore what the host and the PowerPC guest compute. */
#define kPoly 0xEDB88320UL

static unsigned long g_table[256];
static int g_built;

/* `unsigned long` is 32 bits on this toolchain and 64 on the host cc that
 * runs the native test, so every step that could carry past bit 31 is
 * masked. Without this the host build and the 68K build disagree on any
 * input at all, and the test would pass on the machine that cannot ship. */
#define kMask 0xFFFFFFFFUL

static void build_table(void)
{
    int i, bit;

    for (i = 0; i < 256; ++i) {
        unsigned long c = (unsigned long)i;

        for (bit = 0; bit < 8; ++bit) {
            c = (c & 1UL) ? (kPoly ^ (c >> 1)) : (c >> 1);
        }
        g_table[i] = c & kMask;
    }
    g_built = 1;
}

unsigned long now68k_crc32(unsigned long crc, const void *bytes, long len)
{
    const unsigned char *p = (const unsigned char *)bytes;
    unsigned long c;

    if (!g_built) {
        build_table();
    }
    if (len <= 0) {
        return crc & kMask;
    }
    /* zlib's convention: the value the caller holds between calls is the
     * FINISHED crc, so each call un-finishes it (the ^ kMask), accumulates,
     * and finishes it again. That is what makes the composition property
     * hold across arbitrary splits - see the header. */
    c = (crc & kMask) ^ kMask;
    while (len-- > 0) {
        c = g_table[(c ^ *p++) & 0xFFUL] ^ (c >> 8);
        c &= kMask;
    }
    return c ^ kMask;
}
