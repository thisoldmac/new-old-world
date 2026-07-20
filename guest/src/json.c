#include "json.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

const char *now_json_value(const char *json, const char *key)
{
    char pattern[48];
    const char *p;

    if (json == NULL || key == NULL) {
        return NULL;
    }
    snprintf(pattern, sizeof pattern, "\"%s\"", key);
    p = strstr(json, pattern);
    if (p == NULL) {
        return NULL;
    }
    p += strlen(pattern);
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
        ++p;
    }
    if (*p != ':') {
        return NULL;
    }
    ++p;
    while (*p == ' ' || *p == '\t' || *p == '\n' || *p == '\r') {
        ++p;
    }
    return p;
}

int now_json_find_string(const char *json, const char *key,
                         char *out, long cap)
{
    const char *p = now_json_value(json, key);
    long n = 0;

    if (p == NULL || *p != '"' || out == NULL || cap < 1) {
        return 0;
    }
    ++p;
    while (*p != '\0' && *p != '"' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return 1;
}

long now_json_find_int(const char *json, const char *key, long fallback)
{
    const char *p = now_json_value(json, key);

    if (p == NULL) {
        return fallback;
    }
    return strtol(p, NULL, 10);
}

int now_json_find_bool(const char *json, const char *key, int fallback)
{
    const char *p = now_json_value(json, key);

    if (p == NULL) {
        return fallback;
    }
    return strncmp(p, "true", 4) == 0;
}

int now_json_type_is(const char *json, const char *type)
{
    char value[48];

    if (type == NULL) {
        return 0;
    }
    if (!now_json_find_string(json, "type", value, sizeof value)) {
        return 0;
    }
    return strcmp(value, type) == 0;
}

/* MacRoman 0x80..0xFF to Unicode. The Mac's own encoding is not ASCII
   and not Latin-1; without this table an accented file name reaches the
   host as invalid UTF-8. */
static const unsigned short k_macroman_high[128] = {
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7
};

void now_json_escape(const char *src, char *out, long cap)
{
    long n = 0;

    if (out == NULL || cap < 1) {
        return;
    }
    if (src == NULL) {
        out[0] = '\0';
        return;
    }
    for (; *src != '\0'; ++src) {
        unsigned char c = (unsigned char)*src;
        char piece[8];
        long len;

        if (c == '"') {
            strcpy(piece, "\\\"");
            len = 2;
        } else if (c == '\\') {
            strcpy(piece, "\\\\");
            len = 2;
        } else if (c >= 0x80) {
            snprintf(piece, sizeof piece, "\\u%04X",
                     (unsigned)k_macroman_high[c - 0x80]);
            len = 6;
        } else if (c < 0x20 || c == 0x7F) {
            snprintf(piece, sizeof piece, "\\u%04X", (unsigned)c);
            len = 6;
        } else {
            piece[0] = (char)c;
            piece[1] = '\0';
            len = 1;
        }
        if (n + len >= cap) {
            break;
        }
        memcpy(out + n, piece, (size_t)len);
        n += len;
    }
    out[n] = '\0';
}
