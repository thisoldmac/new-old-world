#include "cmd_line.h"

#include <stdlib.h>
#include <string.h>

#include "json.h"

/* The longest console line this reads. The host's field is unbounded and the
   control frame caps at 4 KB, but every argument these commands take is a
   name, a path or a flag: 255 bytes is longer than any HFS path this
   File Manager can open, so a line beyond it cannot be naming something
   reachable. It is clamped rather than refused because the clamp cannot
   change what a valid line means. */
enum { kLineMax = 256 };

static int is_space(char c)
{
    return c == ' ' || c == '\t';
}

static void trim_into(const char *src, char *out, long cap)
{
    long n = 0;

    if (out == NULL || cap < 1) {
        return;
    }
    while (is_space(*src)) {
        ++src;
    }
    while (*src != '\0' && n + 1 < cap) {
        out[n++] = *src++;
    }
    while (n > 0 && is_space(out[n - 1])) {
        --n;
    }
    out[n] = '\0';
}

int now_cmd_line(const char *request_json, char *out, long cap)
{
    if (out == NULL || cap < 1) {
        return 0;
    }
    out[0] = '\0';
    /* find_TEXT, never find_string: a line carries HFS names ("ls
       Café:Notes") and the host sends them as UTF-8, which the File Manager
       cannot use undecoded. */
    return now_json_find_text(request_json, "line", out, cap) != 0;
}

void now_cmd_arg_rest(const char *request_json, const char *key,
                      char *out, long cap)
{
    char line[kLineMax];

    if (out == NULL || cap < 1) {
        return;
    }
    out[0] = '\0';
    if (now_json_find_text(request_json, key, out, cap)) {
        return;
    }
    if (!now_cmd_line(request_json, line, (long)sizeof line)) {
        return;
    }
    trim_into(line, out, cap);
}

void now_cmd_arg_word(const char *request_json, const char *key,
                      char *out, long cap)
{
    char line[kLineMax];
    const char *p;
    long n = 0;

    if (out == NULL || cap < 1) {
        return;
    }
    out[0] = '\0';
    if (now_json_find_string(request_json, key, out, cap)) {
        return;
    }
    if (!now_cmd_line(request_json, line, (long)sizeof line)) {
        return;
    }
    for (p = line; *p != '\0';) {
        while (is_space(*p)) {
            ++p;
        }
        if (*p == '\0') {
            break;
        }
        if (*p == '-') {                      /* a flag: skip the word */
            while (*p != '\0' && !is_space(*p)) {
                ++p;
            }
            continue;
        }
        while (*p != '\0' && !is_space(*p) && n + 1 < cap) {
            out[n++] = *p++;
        }
        break;
    }
    out[n] = '\0';
}

void now_cmd_first_word(const char *line, char *out, long cap)
{
    long n = 0;

    if (out == NULL || cap < 1) {
        return;
    }
    out[0] = '\0';
    if (line == NULL) {
        return;
    }
    while (is_space(*line)) {
        ++line;
    }
    while (*line != '\0' && !is_space(*line) && n + 1 < cap) {
        out[n++] = *line++;
    }
    out[n] = '\0';
}

int now_cmd_line_word(const char *line, const char *word)
{
    const char *p = line;
    long len;

    if (line == NULL || word == NULL) {
        return 0;
    }
    len = (long)strlen(word);
    while (*p != '\0') {
        while (is_space(*p)) {
            ++p;
        }
        if (*p == '\0') {
            break;
        }
        if (strncmp(p, word, (size_t)len) == 0
            && (p[len] == '\0' || is_space(p[len]))) {
            return 1;
        }
        while (*p != '\0' && !is_space(*p)) {
            ++p;
        }
    }
    return 0;
}

int now_cmd_line_flag_value(const char *line, const char *flag,
                            char *out, long cap)
{
    const char *p = line;
    long len;
    long n = 0;

    if (out == NULL || cap < 1) {
        return 0;
    }
    out[0] = '\0';
    if (line == NULL || flag == NULL) {
        return 0;
    }
    len = (long)strlen(flag);
    while (*p != '\0') {
        while (is_space(*p)) {
            ++p;
        }
        if (*p == '\0') {
            break;
        }
        if (strncmp(p, flag, (size_t)len) == 0
            && (p[len] == '\0' || is_space(p[len]))) {
            p += len;
            while (is_space(*p)) {
                ++p;
            }
            while (*p != '\0' && !is_space(*p) && n + 1 < cap) {
                out[n++] = *p++;
            }
            out[n] = '\0';
            return n > 0;
        }
        while (*p != '\0' && !is_space(*p)) {
            ++p;
        }
    }
    return 0;
}

int now_cmd_line_int(const char *line, long *out)
{
    const char *p = line;

    if (line == NULL || out == NULL) {
        return 0;
    }
    while (*p != '\0') {
        if (*p >= '0' && *p <= '9') {
            *out = strtol(p, NULL, 10);
            return 1;
        }
        ++p;
    }
    return 0;
}
