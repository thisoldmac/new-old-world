#include "sw_vers_parse.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* The four stage bytes name themselves; anything else is a resource we
   do not recognise, and saying "stage?" is more honest than guessing. */
static const char *stage_name(unsigned char stage)
{
    switch (stage) {
    case 0x20: return "development";
    case 0x40: return "alpha";
    case 0x60: return "beta";
    case 0x80: return "final";
    default:   return "stage?";
    }
}

/* Copy a Pascal-style run of `len` bytes into `dst`, clamped to the
   buffer, always NUL-terminated. `len` is already bounded to the handle
   by the caller; this bounds it to the buffer, the second of the two
   fences every field crosses. */
static void bounded_copy(char *dst, long cap, const unsigned char *src,
                         long len)
{
    if (dst == NULL || cap <= 0) {
        return;
    }
    if (len > cap - 1) {
        len = cap - 1;
    }
    if (len > 0) {
        memcpy(dst, src, (size_t)len);
    }
    dst[len > 0 ? len : 0] = '\0';
}

int sw_parse_vers(const unsigned char *bytes, long size,
                  char *shortv, long shortcap,
                  char *numeric, long numcap,
                  char *info, long infocap)
{
    long shortlen;

    if (shortv != NULL && shortcap > 0) {
        shortv[0] = '\0';
    }
    if (numeric != NULL && numcap > 0) {
        numeric[0] = '\0';
    }
    if (info != NULL && infocap > 0) {
        info[0] = '\0';
    }

    /* Byte 6 is the short-version length; without it there is no version
       to yield. A shorter resource is a truncated old file — data, not a
       defect — so it reads as absent rather than crashing. */
    if (bytes == NULL || size < 7) {
        return 0;
    }

    /* Short version: length bounded to the handle, then to the buffer. */
    shortlen = bytes[6];
    if (7 + shortlen > size) {
        shortlen = size - 7;
    }
    bounded_copy(shortv, shortcap, bytes + 7, shortlen);

    /* Numeric: BCD major printed as hex (%x) to match every existing
       rendering, minor/bugfix as the two nibbles, then the stage; a
       non-final stage with a non-zero revision is a prerelease. */
    if (numeric != NULL && numcap > 0) {
        snprintf(numeric, (size_t)numcap, "%x.%x.%x %s%s",
                 (unsigned int)bytes[0],
                 (unsigned int)((bytes[1] >> 4) & 0xF),
                 (unsigned int)(bytes[1] & 0xF),
                 stage_name(bytes[2]),
                 bytes[2] != 0x80 && bytes[3] != 0 ? " (prerelease)" : "");
    }

    /* Get Info string: it follows the short one, so it exists only when
       a byte remains past it for its own length. */
    if (info != NULL && infocap > 0 && 7 + bytes[6] < size) {
        const unsigned char *ls = bytes + 7 + bytes[6];
        long infolen = ls[0];

        if ((ls - bytes) + 1 + infolen > size) {
            infolen = size - (ls - bytes) - 1;
        }
        bounded_copy(info, infocap, ls + 1, infolen);
    }

    return 1;
}
