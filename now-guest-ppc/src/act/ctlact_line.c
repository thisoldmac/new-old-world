#include "ctlact_line.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int is_space(char c)
{
    return c == ' ' || c == '\t';
}

/* One word, advanced past. Returns NULL at the end of the line. */
static const char *word(const char *p, char *out, long cap)
{
    long n = 0;

    while (*p != '\0' && is_space(*p)) ++p;
    if (*p == '\0') return 0;
    while (*p != '\0' && !is_space(*p)) {
        if (out != 0 && n + 1 < cap) out[n++] = *p;
        ++p;
    }
    if (out != 0 && cap > 0) out[n] = '\0';
    return p;
}

/* A whole word that is a decimal integer, and nothing else. `strtol`
   alone accepts "21abc" and stops at the letters, which would turn a
   typo into a confident part code. */
static int whole_int(const char *w, long *out)
{
    char *end = 0;
    long  v;

    if (w == 0 || w[0] == '\0') return 0;
    v = strtol(w, &end, 10);
    if (end == w || (end != 0 && *end != '\0')) return 0;
    *out = v;
    return 1;
}

int now_ctlact_parse_line(const char *line, char *element, long cap,
                          long *part, int *has_point, long *h, long *v,
                          int *half_point)
{
    char        buf[32];
    const char *p;

    *has_point = 0;
    *half_point = 0;
    *part = 0;
    *h = 0;
    *v = 0;
    if (element != 0 && cap > 0) element[0] = '\0';
    if (line == 0) return 0;

    p = word(line, element, cap);
    if (p == 0 || element == 0 || element[0] == '\0') return 0;

    p = word(p, buf, (long)sizeof buf);
    if (p == 0 || !whole_int(buf, part)) return 0;

    p = word(p, buf, (long)sizeof buf);
    if (p == 0) return 1;                       /* no point: the centre */
    if (!whole_int(buf, h)) return 0;

    p = word(p, buf, (long)sizeof buf);
    if (p == 0 || !whole_int(buf, v)) {
        /* An h with no v. Reported rather than treated as no point at
           all: the caller meant to aim and the line is wrong, and
           silently pressing the centre would be the act landing
           somewhere the person did not type. */
        *half_point = 1;
        return 0;
    }
    *has_point = 1;
    return 1;
}

int now_ctlact_line_request(const char *element, long part, int has_point,
                            long h, long v, char *out, long cap)
{
    int n;

    if (out == 0 || cap < 1) return 0;
    out[0] = '\0';
    if (element == 0 || element[0] == '\0') return 0;
    /* A reference is minted by this Mac and is hex and hyphens - there is
       nothing in one to escape, and this deliberately does not become a
       general JSON writer that could be handed something that does. */
    if (strpbrk(element, "\"\\") != 0) return 0;
    if (has_point) {
        n = snprintf(out, (size_t)cap,
                     "{\"args\":{\"element\":\"%s\",\"part\":%ld,"
                     "\"h\":%ld,\"v\":%ld}}", element, part, h, v);
    } else {
        n = snprintf(out, (size_t)cap,
                     "{\"args\":{\"element\":\"%s\",\"part\":%ld}}",
                     element, part);
    }
    if (n < 0 || (long)n >= cap) {
        out[0] = '\0';
        return 0;
    }
    return 1;
}
