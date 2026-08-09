/* axref.c - strict parser/builder for pointer-free UI references. */
#include "axref.h"

#include <stdio.h>
#include <string.h>

static int is_unreserved(unsigned char c)
{
    return (c >= 'A' && c <= 'Z') || (c >= 'a' && c <= 'z')
        || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.'
        || c == '~';
}

static int hex_value(unsigned char c)
{
    if (c >= '0' && c <= '9') {
        return c - '0';
    }
    if (c >= 'A' && c <= 'F') {
        return c - 'A' + 10;
    }
    if (c >= 'a' && c <= 'f') {
        return c - 'a' + 10;
    }
    return -1;
}

uint32_t ax_ref_node_fingerprint(uint32_t serial_hi, uint32_t serial_lo,
                                 uint32_t window_address,
                                 uint32_t control_handle)
{
    uint32_t values[4];
    uint32_t hash = UINT32_C(2166136261);
    unsigned int i;
    unsigned int byte;

    values[0] = serial_hi;
    values[1] = serial_lo;
    values[2] = window_address;
    values[3] = control_handle;
    for (i = 0; i < 4; i++) {
        for (byte = 0; byte < 4; byte++) {
            hash ^= (values[i] >> (byte * 8)) & 0xffU;
            hash *= UINT32_C(16777619);
        }
    }
    return hash;
}

static int append_text(char *out, size_t cap, size_t *used,
                       const char *text, size_t len)
{
    if (*used >= cap || len >= cap - *used) {
        return AX_REF_OVERFLOW;
    }
    memcpy(out + *used, text, len);
    *used += len;
    out[*used] = '\0';
    return AX_REF_OK;
}

static int append_title(char *out, size_t cap, size_t *used,
                        const unsigned char *title, size_t len)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t i;

    if (len > AX_REF_TITLE_MAX || (len != 0 && title == NULL)) {
        return AX_REF_INVALID;
    }
    for (i = 0; i < len;) {
        if (is_unreserved(title[i])) {
            size_t start = i++;

            while (i < len && is_unreserved(title[i])) {
                i++;
            }
            if (append_text(out, cap, used, (const char *)title + start,
                            i - start) != AX_REF_OK) {
                return AX_REF_OVERFLOW;
            }
        } else {
            char encoded[3];

            encoded[0] = '%';
            encoded[1] = hex[title[i] >> 4];
            encoded[2] = hex[title[i] & 0x0f];
            if (append_text(out, cap, used, encoded, sizeof(encoded))
                != AX_REF_OK) {
                return AX_REF_OVERFLOW;
            }
            i++;
        }
    }
    return AX_REF_OK;
}

static int append_occurrence(char *out, size_t cap, size_t *used,
                             unsigned int occurrence)
{
    char value[6];
    int  n;

    if (occurrence > 65535U) {
        return AX_REF_INVALID;
    }
    n = snprintf(value, sizeof(value), "%u", occurrence);
    if (n < 0 || (size_t)n >= sizeof(value)) {
        return AX_REF_INVALID;
    }
    return append_text(out, cap, used, value, (size_t)n);
}

int ax_ref_build(char *out, size_t cap, const ax_ref *ref)
{
    char   prefix[29];
    char   suffix[15];
    size_t used = 0;
    int    n;
    int    rc;

    if (out == NULL || cap == 0 || ref == NULL
        || ref->window_title_len > AX_REF_TITLE_MAX
        || ref->control_title_len > AX_REF_TITLE_MAX) {
        return AX_REF_INVALID;
    }
    out[0] = '\0';
    n = snprintf(prefix, sizeof(prefix),
                 "ax2/%08lX%08lX/window:",
                 (unsigned long)ref->serial_hi,
                 (unsigned long)ref->serial_lo);
    if (n < 0 || (size_t)n >= sizeof(prefix)) {
        return AX_REF_INVALID;
    }
    rc = append_text(out, cap, &used, prefix, (size_t)n);
    if (rc == AX_REF_OK) {
        rc = append_title(out, cap, &used, ref->window_title,
                          ref->window_title_len);
    }
    if (rc == AX_REF_OK) {
        rc = append_text(out, cap, &used, "#", 1);
    }
    if (rc == AX_REF_OK) {
        rc = append_occurrence(out, cap, &used, ref->window_occurrence);
    }
    if (rc == AX_REF_OK) {
        rc = append_text(out, cap, &used, "/control:", 9);
    }
    if (rc == AX_REF_OK) {
        rc = append_title(out, cap, &used, ref->control_title,
                          ref->control_title_len);
    }
    if (rc == AX_REF_OK) {
        rc = append_text(out, cap, &used, "#", 1);
    }
    if (rc == AX_REF_OK) {
        rc = append_occurrence(out, cap, &used, ref->control_occurrence);
    }
    if (rc == AX_REF_OK) {
        n = snprintf(suffix, sizeof(suffix), "/node:%08lX",
                     (unsigned long)ref->node_fingerprint);
        if (n < 0 || (size_t)n >= sizeof(suffix)) {
            rc = AX_REF_INVALID;
        } else {
            rc = append_text(out, cap, &used, suffix, (size_t)n);
        }
    }
    if (rc != AX_REF_OK) {
        out[0] = '\0';
    }
    return rc;
}

static int parse_hex32(const char *text, uint32_t *out)
{
    uint32_t value = 0;
    int      i;

    for (i = 0; i < 8; i++) {
        int digit = hex_value((unsigned char)text[i]);

        if (digit < 0) {
            return AX_REF_INVALID;
        }
        value = (value << 4) | (uint32_t)digit;
    }
    *out = value;
    return AX_REF_OK;
}

static int parse_title(const char *start, const char *end,
                       unsigned char out[AX_REF_TITLE_MAX + 1],
                       size_t *out_len)
{
    size_t used = 0;

    while (start < end) {
        unsigned char value = (unsigned char)*start++;

        if (value == '%') {
            int hi;
            int lo;

            if (end - start < 2) {
                return AX_REF_INVALID;
            }
            hi = hex_value((unsigned char)start[0]);
            lo = hex_value((unsigned char)start[1]);
            if (hi < 0 || lo < 0) {
                return AX_REF_INVALID;
            }
            value = (unsigned char)((hi << 4) | lo);
            start += 2;
        } else if (!is_unreserved(value)) {
            return AX_REF_INVALID;
        }
        if (used >= AX_REF_TITLE_MAX) {
            return AX_REF_INVALID;
        }
        out[used++] = value;
    }
    out[used] = '\0';
    *out_len = used;
    return AX_REF_OK;
}

static int parse_occurrence(const char *start, const char *end,
                            unsigned int *out)
{
    unsigned int value = 0;

    if (start == end || (end - start > 1 && *start == '0')) {
        return AX_REF_INVALID;
    }
    while (start < end) {
        unsigned int digit;

        if (*start < '0' || *start > '9') {
            return AX_REF_INVALID;
        }
        digit = (unsigned int)(*start++ - '0');
        if (value > (65535U - digit) / 10U) {
            return AX_REF_INVALID;
        }
        value = value * 10U + digit;
    }
    *out = value;
    return AX_REF_OK;
}

int ax_ref_parse(const char *text, size_t len, ax_ref *out)
{
    const char *p;
    const char *end;
    const char *mark;
    const char *slash;

    if (text == NULL || out == NULL
        || len < 4 + 16 + 8 + 2 + 9 + 2 + 14
        || len >= AX_REF_MAX || memcmp(text, "ax2/", 4) != 0) {
        return AX_REF_INVALID;
    }
    memset(out, 0, sizeof(*out));
    p = text + 4;
    end = text + len;
    if (parse_hex32(p, &out->serial_hi) != AX_REF_OK
        || parse_hex32(p + 8, &out->serial_lo) != AX_REF_OK) {
        return AX_REF_INVALID;
    }
    p += 16;
    if (end - p < 8 || memcmp(p, "/window:", 8) != 0) {
        return AX_REF_INVALID;
    }
    p += 8;
    mark = memchr(p, '#', (size_t)(end - p));
    if (mark == NULL
        || parse_title(p, mark, out->window_title,
                       &out->window_title_len) != AX_REF_OK) {
        return AX_REF_INVALID;
    }
    p = mark + 1;
    slash = memchr(p, '/', (size_t)(end - p));
    if (slash == NULL
        || parse_occurrence(p, slash, &out->window_occurrence) != AX_REF_OK
        || end - slash < 9 || memcmp(slash, "/control:", 9) != 0) {
        return AX_REF_INVALID;
    }
    p = slash + 9;
    mark = memchr(p, '#', (size_t)(end - p));
    if (mark == NULL
        || parse_title(p, mark, out->control_title,
                       &out->control_title_len) != AX_REF_OK) {
        return AX_REF_INVALID;
    }
    slash = memchr(mark + 1, '/', (size_t)(end - mark - 1));
    if (slash == NULL
        || parse_occurrence(mark + 1, slash, &out->control_occurrence)
           != AX_REF_OK
        || end - slash != 14 || memcmp(slash, "/node:", 6) != 0
        || parse_hex32(slash + 6, &out->node_fingerprint) != AX_REF_OK) {
        return AX_REF_INVALID;
    }
    return AX_REF_OK;
}
