#include "connfields.h"

#include <stddef.h>   /* NULL */

/* No <string.h> strlcpy under Retro68's libc, and we do not want a
 * dependency on one existing - copy into a fixed buffer by hand. */
static void copy_reason(char *dst, const char *src)
{
    int i = 0;

    while (src[i] != '\0' && i < kConnReasonMax - 1) {
        dst[i] = src[i];
        i++;
    }
    dst[i] = '\0';
}

/* Indices into kHostReasonText - see the comment there for why the
 * function threads an index through instead of calling copy_reason
 * at each rejection site. */
enum {
    kHostReasonOk = 0,
    kHostReasonEmpty,
    kHostReasonTooManyDigits,
    kHostReasonEmptyOctet,
    kHostReasonNonDigit,
    kHostReasonOctetOver255,
    kHostReasonTooManyOctets,
    kHostReasonTrailingGarbage,
    kHostReasonTooFewOctets
};

/* now_conn_host_validate has nine rejection points; calling copy_reason
 * at each one gave the compiler nine call sites small enough to inline,
 * so the byte-by-byte copy loop was duplicated in the compiled object
 * instead of shared. Routing every path through one reason index and
 * one copy_reason call at the bottom keeps exactly one copy of that
 * loop, decimal-quad host on a 384 KB partition (see AGENTS.md). */
static const char *const kHostReasonText[] = {
    "ok",
    "address is empty",
    "octet has too many digits",
    "empty octet",
    "non-digit character",
    "octet over 255",
    "too many octets",
    "trailing garbage",
    "too few octets"
};

ConnHostResult now_conn_host_validate(const char *text)
{
    ConnHostResult r;
    unsigned long  addr = 0;
    int            octet_count = 0;
    int            reason = kHostReasonOk;
    const char    *p;

    r.ok = 0;
    r.addr = 0;

    if (text == NULL || text[0] == '\0') {
        reason = kHostReasonEmpty;
        goto done;
    }

    p = text;
    for (;;) {
        int          digits = 0;
        unsigned int value = 0;

        while (*p >= '0' && *p <= '9') {
            value = value * 10 + (unsigned int)(*p - '0');
            digits++;
            p++;
            if (digits > 3) {
                reason = kHostReasonTooManyDigits;
                goto done;
            }
        }

        if (digits == 0) {
            reason = (*p == '.' || *p == '\0') ? kHostReasonEmptyOctet
                                                : kHostReasonNonDigit;
            goto done;
        }
        if (value > 255) {
            reason = kHostReasonOctetOver255;
            goto done;
        }

        addr = (addr << 8) | (unsigned long)value;
        octet_count++;

        if (*p == '.') {
            if (octet_count == 4) {
                reason = kHostReasonTooManyOctets;
                goto done;
            }
            p++;
            continue;
        }
        break;
    }

    if (*p != '\0') {
        reason = kHostReasonTrailingGarbage;
        goto done;
    }
    if (octet_count != 4) {
        reason = kHostReasonTooFewOctets;
        goto done;
    }

    r.ok = 1;
    r.addr = addr;

done:
    copy_reason(r.reason, kHostReasonText[reason]);
    return r;
}

ConnPortResult now_conn_port_validate(const char *text)
{
    ConnPortResult r;
    unsigned long  value = 0;
    int            digits = 0;
    const char    *p;

    r.ok = 0;
    r.port = 0;

    if (text == NULL || text[0] == '\0') {
        copy_reason(r.reason, "port is empty");
        return r;
    }

    for (p = text; *p != '\0'; p++) {
        if (*p < '0' || *p > '9') {
            copy_reason(r.reason, "non-digit character");
            return r;
        }
        value = value * 10 + (unsigned long)(*p - '0');
        digits++;
        if (digits > 5 || value > 65535UL) {
            copy_reason(r.reason, "port over 65535");
            return r;
        }
    }

    if (value < 1) {
        copy_reason(r.reason, "port must be at least 1");
        return r;
    }

    r.ok = 1;
    r.port = (unsigned short)value;
    copy_reason(r.reason, "ok");
    return r;
}

ConnTimeoutResult now_conn_timeout_validate(const char *text)
{
    ConnTimeoutResult r;
    unsigned long      value = 0;
    int                digits = 0;
    const char        *p;

    r.ok = 0;
    r.seconds = 0;

    if (text == NULL || text[0] == '\0') {
        copy_reason(r.reason, "timeout is empty");
        return r;
    }

    for (p = text; *p != '\0'; p++) {
        if (*p < '0' || *p > '9') {
            copy_reason(r.reason, "non-digit character");
            return r;
        }
        value = value * 10 + (unsigned long)(*p - '0');
        digits++;
        if (digits > 3 || value > (unsigned long)kConnTimeoutMaxSecs) {
            copy_reason(r.reason, "timeout over 60 s");
            return r;
        }
    }

    if (value < (unsigned long)kConnTimeoutMinSecs) {
        copy_reason(r.reason, "timeout must be at least 1 s");
        return r;
    }

    r.ok = 1;
    r.seconds = (short)value;
    copy_reason(r.reason, "ok");
    return r;
}
