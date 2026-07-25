#include "numfmt.h"

#include <string.h>

int now68k_fmt_append_str(char *buf, long cap, long *pos, const char *s)
{
    size_t len = strlen(s);

    if (*pos < 0 || (long)len > cap - *pos) {
        return 0;
    }
    memcpy(buf + *pos, s, len);
    *pos += (long)len;
    return 1;
}

int now68k_fmt_append_long(char *buf, long cap, long *pos, long value)
{
    char digits[24];   /* sign + max decimal digits of a 64-bit long */
    int n = 0;
    unsigned long mag;
    int neg = value < 0;

    /* Go through unsigned long so negating LONG_MIN (which cannot be
     * represented as a positive long) is well-defined instead of
     * undefined signed overflow. */
    mag = neg ? (unsigned long)(-(value + 1)) + 1UL : (unsigned long)value;

    do {
        digits[n++] = (char)('0' + (mag % 10UL));
        mag /= 10UL;
    } while (mag != 0UL && n < (int)sizeof digits);

    if (neg && n < (int)sizeof digits) {
        digits[n++] = '-';
    }

    if (*pos < 0 || n > cap - *pos) {
        return 0;
    }
    while (n > 0) {
        buf[(*pos)++] = digits[--n];
    }
    return 1;
}
