/*
 * wire.c - JSON envelope helpers for the harness.
 */
#include "wire.h"

#include <string.h>
#include <stdio.h>

/* Return a pointer to the first char of the value for key `key`, or NULL.
 *
 * Tokenizes strings as it scans, so a `"key":` sequence that appears *inside a
 * string value* (e.g. file `data` that itself looks like JSON) is never mistaken
 * for a key. A quoted token is a key only when the next non-space char is ':'.
 * Not a full JSON parser, but correct about the string-vs-key boundary - which
 * matters now that `write` carries arbitrary bytes. */
/* Flat, first-match-wins key scan over the whole message (we control both ends,
 * so a full parser is overkill). Caveat: it does NOT respect object nesting, so
 * an arg key that shares a name with an envelope key (`proto`/`id`/`verb`) will
 * resolve to the envelope's copy, which appears first. Don't name args after
 * envelope keys - the transfer handle is `handle`, not `id`, for exactly this. */
static const char *find_value(const char *json, size_t len, const char *key)
{
    size_t klen = strlen(key);
    const char *end = json + len;
    const char *p = json;

    while (p < end) {
        if (*p == '"') {
            const char *s = p + 1;               /* scan to the closing quote */
            const char *q;

            while (s < end && *s != '"') {
                if (*s == '\\' && (s + 1) < end) {
                    s++;                         /* skip the escaped char */
                }
                s++;
            }
            /* s is at the closing quote (or end). Peek past ws for ':'. */
            q = (s < end) ? s + 1 : end;
            while (q < end && (*q == ' ' || *q == '\t')) {
                q++;
            }
            if (q < end && *q == ':') {          /* this token is a key */
                if ((size_t)(s - (p + 1)) == klen
                    && strncmp(p + 1, key, klen) == 0) {
                    q++;                         /* past ':' */
                    while (q < end && (*q == ' ' || *q == '\t')) {
                        q++;
                    }
                    return (q < end) ? q : NULL;
                }
                p = q;                           /* non-match: scan its value */
            } else {
                p = (s < end) ? s + 1 : end;     /* value string: skip it whole */
            }
        } else {
            p++;
        }
    }
    return NULL;
}

int wire_find_int(const char *json, size_t len, const char *key, long *out)
{
    const char *p = find_value(json, len, key);
    const char *end = json + len;
    long sign = 1;
    long v = 0;

    if (p == NULL) {
        return 0;
    }
    if (*p == '-') {
        sign = -1;
        p++;
    }
    if (p >= end || *p < '0' || *p > '9') {
        return 0;
    }
    while (p < end && *p >= '0' && *p <= '9') {
        if (v > (2147483647L - 9) / 10) {   /* saturate rather than overflow */
            v = 2147483647L;
            break;
        }
        v = v * 10 + (*p - '0');
        p++;
    }
    *out = sign * v;
    return 1;
}

int wire_find_u32(const char *json, size_t len, const char *key, uint32_t *out)
{
    const char *p = find_value(json, len, key);
    const char *end = json + len;
    uint32_t    value = 0;

    if (p == NULL || out == NULL || p >= end || *p < '0' || *p > '9') {
        return 0;
    }
    if (*p == '0' && p + 1 < end && p[1] >= '0' && p[1] <= '9') {
        return 0;
    }
    while (p < end && *p >= '0' && *p <= '9') {
        uint32_t digit = (uint32_t)(*p++ - '0');

        if (value > (UINT32_MAX - digit) / 10U) {
            return 0;
        }
        value = value * 10U + digit;
    }
    while (p < end && (*p == ' ' || *p == '\t'
                       || *p == '\r' || *p == '\n')) {
        p++;
    }
    if (p >= end || (*p != ',' && *p != '}' && *p != ']')) {
        return 0;
    }
    *out = value;
    return 1;
}

int wire_find_bool(const char *json, size_t len, const char *key, int *out)
{
    const char *p = find_value(json, len, key);

    if (p == NULL) {
        return 0;
    }
    if (*p == 't') {            /* true  */
        *out = 1;
        return 1;
    }
    if (*p == 'f') {            /* false */
        *out = 0;
        return 1;
    }
    if (*p >= '0' && *p <= '9') {
        *out = (*p != '0');
        return 1;
    }
    return 0;
}

int wire_find_str(const char *json, size_t len, const char *key,
                  char *out, size_t outcap)
{
    const char *p = find_value(json, len, key);
    const char *end = json + len;
    size_t n = 0;

    if (p == NULL || p >= end || *p != '"') {
        return kWireAbsent;
    }
    if (outcap == 0) {
        return kWireOverflow;
    }
    p++;    /* opening quote */
    while (p < end && *p != '"') {
        char c = *p;
        if (c == '\\' && (p + 1) < end) {
            p++;
            switch (*p) {
            case 'n': c = '\n'; break;
            case 't': c = '\t'; break;
            case 'r': c = '\r'; break;
            default:  c = *p;   break;   /* covers \" and \\ */
            }
        }
        if (n + 1 >= outcap) {
            out[n] = '\0';                /* truncated prefix, loggable */
            return kWireOverflow;
        }
        out[n++] = c;
        p++;
    }
    if (p >= end) {
        out[n] = '\0';
        return kWireAbsent;               /* unterminated string */
    }
    out[n] = '\0';
    return (int)n;
}

int wire_resp_error(char *out, size_t cap, long id,
                    const char *code, const char *message)
{
    int n = snprintf(out, cap,
        "{\"proto\":1,\"id\":%ld,\"ok\":false,"
        "\"error\":{\"code\":\"%s\",\"message\":\"%s\"},"
        "\"backing\":\"" TBT_BACKING "\"}\n",
        id, code, message);
    return (n < 0 || (size_t)n >= cap) ? -1 : n;
}

int wire_base64(const unsigned char *in, size_t inlen, char *out, size_t outcap)
{
    static const char tbl[] =
        "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    size_t i = 0;
    size_t o = 0;

    while (i < inlen) {
        unsigned long v = 0;
        int           n = 0;
        int           j;

        for (j = 0; j < 3; j++) {
            v <<= 8;
            if (i < inlen) {
                v |= in[i++];
                n++;
            }
        }
        if (o + 4 >= outcap) {
            return -1;
        }
        out[o++] = tbl[(v >> 18) & 0x3F];
        out[o++] = tbl[(v >> 12) & 0x3F];
        out[o++] = (n >= 2) ? tbl[(v >> 6) & 0x3F] : '=';
        out[o++] = (n >= 3) ? tbl[v & 0x3F] : '=';
    }
    if (o >= outcap) {
        return -1;
    }
    out[o] = '\0';
    return (int)o;
}

unsigned long wire_crc32_update(unsigned long crc, const unsigned char *in,
                                size_t inlen)
{
    /* Bitwise (table-free): the PB1400 is RAM-tight and a transfer is bounded, so
       trading a 1 KB table for a few cycles per byte is the right call here. */
    size_t i;
    int    b;

    for (i = 0; i < inlen; i++) {
        crc ^= in[i];
        for (b = 0; b < 8; b++) {
            crc = (crc & 1UL) ? ((crc >> 1) ^ 0xEDB88320UL) : (crc >> 1);
        }
    }
    return crc;
}

unsigned long wire_crc32(const unsigned char *in, size_t inlen)
{
    return (wire_crc32_update(0xFFFFFFFFUL, in, inlen) ^ 0xFFFFFFFFUL)
           & 0xFFFFFFFFUL;
}

int wire_unbase64(const char *in, size_t inlen, unsigned char *out, size_t outcap)
{
    unsigned long acc = 0;
    int           bits = 0;
    size_t        o = 0;
    size_t        i;

    for (i = 0; i < inlen; i++) {
        int c = (unsigned char)in[i];
        int v;

        if (c == '=') {
            break;                       /* padding: end of data */
        }
        if (c >= 'A' && c <= 'Z') {
            v = c - 'A';
        } else if (c >= 'a' && c <= 'z') {
            v = c - 'a' + 26;
        } else if (c >= '0' && c <= '9') {
            v = c - '0' + 52;
        } else if (c == '+') {
            v = 62;
        } else if (c == '/') {
            v = 63;
        } else {
            continue;                    /* skip whitespace / stray bytes */
        }
        acc = (acc << 6) | (unsigned long)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (o >= outcap) {
                return -1;
            }
            out[o++] = (unsigned char)((acc >> bits) & 0xFF);
        }
    }
    return (int)o;
}

int wire_escape(const char *in, size_t inlen, char *out, size_t outcap)
{
    size_t o = 0;
    size_t i;

    for (i = 0; i < inlen; i++) {
        unsigned char c = (unsigned char)in[i];
        const char *rep;
        char         buf[7];
        size_t       rlen;

        switch (c) {
        case '"':  rep = "\\\""; rlen = 2; break;
        case '\\': rep = "\\\\"; rlen = 2; break;
        case '\n': rep = "\\n";  rlen = 2; break;
        case '\r': rep = "\\r";  rlen = 2; break;
        case '\t': rep = "\\t";  rlen = 2; break;
        default:
            if (c < 0x20 || c >= 0x7f) {
                /* Non-printable and high (Mac Roman) bytes both escape to a
                 * \u00xx byte-value form: the wire is ASCII JSON, so a raw
                 * byte >= 0x7f in a name/title/path would make the frame
                 * invalid UTF-8 for any strict JSON reader. */
                sprintf(buf, "\\u%04x", (unsigned)c);
                rep = buf; rlen = 6;
            } else {
                buf[0] = (char)c;          /* printable ASCII passes through */
                rep = buf; rlen = 1;
            }
            break;
        }
        if (o + rlen >= outcap) {
            return -1;
        }
        memcpy(out + o, rep, rlen);
        o += rlen;
    }
    if (o >= outcap) {
        return -1;
    }
    out[o] = '\0';
    return (int)o;
}

int wire_valid_token_list(const char *list, size_t max_token_len)
{
    const unsigned char *p = (const unsigned char *)list;
    int tokens = 0;

    if (list == NULL || max_token_len == 0) {
        return 0;
    }
    while (*p != '\0') {
        size_t length = 0;

        while (*p == ' ' || *p == ',') {
            p++;
        }
        while (*p != '\0' && *p != ' ' && *p != ',') {
            if (!((*p >= 'a' && *p <= 'z') || (*p >= 'A' && *p <= 'Z')
                  || (*p >= '0' && *p <= '9') || *p == '-' || *p == '_')) {
                return 0;
            }
            length++;
            p++;
        }
        if (length > 0) {
            if (length >= max_token_len) {
                return 0;
            }
            tokens++;
        }
    }
    return tokens > 0;
}
