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
