#include "json_scan.h"

#include <stddef.h>
#include <string.h>

static int is_json_space(char c)
{
    return c == ' ' || c == '\t' || c == '\n' || c == '\r';
}

/* memcmp-based substring search bounded to [hay, hay_end) -- unlike
 * strstr, it never reads past hay_end even if the underlying buffer
 * happens to have no NUL anywhere in range (see json_scan.h). */
static const char *bounded_find(const char *hay, const char *hay_end,
                                 const char *needle, size_t needle_len)
{
    const char *p;

    if (needle_len == 0 || hay > hay_end) {
        return NULL;
    }
    for (p = hay; (size_t)(hay_end - p) >= needle_len; ++p) {
        if (memcmp(p, needle, needle_len) == 0) {
            return p;
        }
    }
    return NULL;
}

const char *now68k_json_value(const char *json, size_t json_len,
                               const char *key)
{
    char pattern[40];
    size_t klen;
    const char *end;
    const char *search;

    if (json == NULL || key == NULL) {
        return NULL;
    }
    klen = strlen(key);
    if (klen + 3 > sizeof pattern) {   /* quote + key + quote + NUL */
        return NULL;
    }
    pattern[0] = '"';
    memcpy(pattern + 1, key, klen);
    pattern[klen + 1] = '"';
    pattern[klen + 2] = '\0';

    end = json + json_len;
    search = json;
    while (search < end) {
        const char *p = bounded_find(search, end, pattern, klen + 2);
        const char *q;

        if (p == NULL) {
            return NULL;
        }
        q = p + klen + 2;
        while (q < end && is_json_space(*q)) {
            ++q;
        }
        if (q < end && *q == ':') {
            ++q;
            while (q < end && is_json_space(*q)) {
                ++q;
            }
            return q;
        }
        /* False match: a quoted "key" occurrence not followed by ':' --
         * most commonly a string VALUE equal to the key name itself
         * (e.g. "note":"id"). Resume just past it instead of giving up
         * the whole search; the real key may still be ahead. */
        search = p + 1;
    }
    return NULL;
}

int now68k_json_find_string(const char *json, size_t json_len,
                             const char *key, char *out, long cap)
{
    const char *end = json + json_len;
    const char *p = now68k_json_value(json, json_len, key);
    long n = 0;

    if (p == NULL || p >= end || *p != '"' || out == NULL || cap < 1) {
        return 0;
    }
    ++p;
    while (p < end && *p != '"' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return (p < end && *p == '"');
}

int now68k_json_read_type(const char *json, size_t json_len, char *out,
                           long cap)
{
    return now68k_json_find_string(json, json_len, "type", out, cap);
}

int now68k_json_find_int(const char *json, size_t json_len, const char *key,
                          long *out)
{
    const char *end = json + json_len;
    const char *p = now68k_json_value(json, json_len, key);
    long v = 0;
    int neg = 0;
    int any = 0;

    if (p == NULL || out == NULL) {
        return 0;
    }
    if (p < end && (*p == '-' || *p == '+')) {
        neg = (*p == '-');
        ++p;
    }
    while (p < end && *p >= '0' && *p <= '9') {
        v = v * 10 + (*p - '0');
        ++p;
        any = 1;
    }
    if (!any) {
        return 0;
    }
    *out = neg ? -v : v;
    return 1;
}

int now68k_json_find_u32(const char *json, size_t json_len, const char *key,
                          unsigned long *out)
{
    const char *end = json + json_len;
    const char *p = now68k_json_value(json, json_len, key);
    unsigned long v = 0;
    int any = 0;

    if (p == NULL || out == NULL) {
        return 0;
    }
    if (p < end && *p == '+') {
        ++p;
    }
    if (p < end && *p == '-') {
        return 0;   /* a CRC is never negative; refuse rather than wrap */
    }
    while (p < end && *p >= '0' && *p <= '9') {
        v = (v * 10UL + (unsigned long)(*p - '0')) & 0xFFFFFFFFUL;
        ++p;
        any = 1;
    }
    if (!any) {
        return 0;
    }
    *out = v;
    return 1;
}
