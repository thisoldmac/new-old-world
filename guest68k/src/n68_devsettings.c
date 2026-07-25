/*
 * n68_devsettings.c - see n68_devsettings.h for the format and for why a
 * malformed line is skipped rather than fatal.
 */
#include "n68_devsettings.h"

#include <stddef.h>   /* NULL */

/* Longest key this file knows is "autoconnect" (11); the cap is generous so
 * a typo'd key is rejected as an unknown key with its own count, not as an
 * over-long one, which is a less useful thing to be told. */
#define kKeyMax   24
/* Longest value is a dotted quad (15). Anything past this is malformed:
 * truncating a value would risk turning nonsense into something that
 * validates. */
#define kValueMax 32

static int is_blank(char c)
{
    return c == ' ' || c == '\t';
}

/* Key normalization, applied once on the way into the compare buffer:
 * upper-case folded down, and '_' read as '-'. Both conventions appear in
 * config files a person has edited before, and neither is worth a rejected
 * line. */
static char norm_key_char(char c)
{
    if (c >= 'A' && c <= 'Z') {
        return (char)(c - 'A' + 'a');
    }
    if (c == '_') {
        return '-';
    }
    return c;
}

static int str_eq(const char *a, const char *b)
{
    int i = 0;

    while (a[i] != '\0' && b[i] != '\0' && a[i] == b[i]) {
        i++;
    }
    return a[i] == '\0' && b[i] == '\0';
}

/* Case-folded compare, for the one kind of value where case is noise: a
 * boolean. Host and port are digits and dots, so this is not needed there. */
static int ci_eq(const char *a, const char *lower)
{
    int i = 0;

    while (a[i] != '\0' && lower[i] != '\0') {
        char c = a[i];

        if (c >= 'A' && c <= 'Z') {
            c = (char)(c - 'A' + 'a');
        }
        if (c != lower[i]) {
            return 0;
        }
        i++;
    }
    return a[i] == '\0' && lower[i] == '\0';
}

/* on/off, yes/no, true/false, 1/0 - all four pairs, in any case, because
 * this is a file a human types from memory and there is no reason to make
 * them guess which spelling this particular program wanted. Returns 0 if
 * `text` is none of them, in which case the line is malformed and the
 * caller counts it. */
static int parse_bool(const char *text, int *out)
{
    if (ci_eq(text, "on") || ci_eq(text, "yes") || ci_eq(text, "true")
        || ci_eq(text, "1")) {
        *out = 1;
        return 1;
    }
    if (ci_eq(text, "off") || ci_eq(text, "no") || ci_eq(text, "false")
        || ci_eq(text, "0")) {
        *out = 0;
        return 1;
    }
    return 0;
}

/* Bounded decimal. Deliberately NOT reusing now_conn_timeout_validate for
 * the retry interval: that validator's 1..60 s range belongs to the connect
 * timeout field and its rejection text is written for a human staring at
 * that field, while a redial cadence measured in minutes is a legitimate
 * thing to want from a file. Host and port DO reuse connfields.c, because
 * there the two ranges are the same range and disagreeing about it would be
 * the actual defect. */
static int parse_uint(const char *text, unsigned long *out)
{
    unsigned long value = 0;
    int           digits = 0;
    int           i;

    for (i = 0; text[i] != '\0'; i++) {
        if (text[i] < '0' || text[i] > '9') {
            return 0;
        }
        value = value * 10 + (unsigned long)(text[i] - '0');
        digits++;
        if (digits > 9) {   /* well past any value here; stops overflow */
            return 0;
        }
    }
    if (digits == 0) {
        return 0;
    }
    *out = value;
    return 1;
}

void n68_devsettings_init(N68DevSettings *s)
{
    int i;

    if (s == NULL) {
        return;
    }
    s->have_host = 0;
    s->host_addr = 0;
    for (i = 0; i < kN68DevHostTextMax; i++) {
        s->host_text[i] = '\0';
    }
    s->have_port = 0;
    s->port = 0;
    s->have_retry = 0;
    s->retry_on = 0;
    s->have_retry_secs = 0;
    s->retry_secs = 0;
    s->have_autoconnect = 0;
    s->autoconnect = 0;
    s->keys_set = 0;
    s->bad_lines = 0;
    s->first_bad_line = 0;
}

static void note_bad(N68DevSettings *s, unsigned short line_no)
{
    if (s->bad_lines < 0xFFFFU) {
        s->bad_lines++;
    }
    if (s->first_bad_line == 0) {
        s->first_bad_line = line_no;
    }
}

/* One key/value pair, both already trimmed and NUL-terminated. Returns 1 if
 * it was understood and applied, 0 if the caller should count the line as
 * malformed. A repeated key overwrites - last one wins, per the header. */
static int apply_pair(N68DevSettings *s, const char *key, const char *value)
{
    if (str_eq(key, "host")) {
        ConnHostResult r;
        int            i;

        /* Length is checked before the validator only so an over-long
         * value cannot silently fill host_text; the validator would reject
         * it too, but on a copy the caller never sees. */
        for (i = 0; value[i] != '\0'; i++) {
            if (i >= kN68DevHostTextMax - 1) {
                return 0;
            }
        }
        r = now_conn_host_validate(value);
        if (!r.ok) {
            return 0;
        }
        s->have_host = 1;
        s->host_addr = r.addr;
        for (i = 0; value[i] != '\0'; i++) {
            s->host_text[i] = value[i];
        }
        s->host_text[i] = '\0';
        return 1;
    }

    if (str_eq(key, "port")) {
        ConnPortResult r = now_conn_port_validate(value);

        if (!r.ok) {
            return 0;
        }
        s->have_port = 1;
        s->port = r.port;
        return 1;
    }

    if (str_eq(key, "retry")) {
        int on;

        if (!parse_bool(value, &on)) {
            return 0;
        }
        s->have_retry = 1;
        s->retry_on = on;
        return 1;
    }

    if (str_eq(key, "retry-interval")) {
        unsigned long secs;

        if (!parse_uint(value, &secs)) {
            return 0;
        }
        if (secs < (unsigned long)kN68DevRetryMinSecs
            || secs > (unsigned long)kN68DevRetryMaxSecs) {
            return 0;
        }
        s->have_retry_secs = 1;
        s->retry_secs = (unsigned short)secs;
        return 1;
    }

    if (str_eq(key, "autoconnect")) {
        int on;

        if (!parse_bool(value, &on)) {
            return 0;
        }
        s->have_autoconnect = 1;
        s->autoconnect = on;
        return 1;
    }

    return 0;   /* unknown key */
}

/* One line, given as [begin, end) of the caller's buffer. */
static void parse_line(N68DevSettings *s, const char *begin, const char *end,
                       unsigned short line_no)
{
    char        key[kKeyMax];
    char        value[kValueMax];
    const char *p = begin;
    const char *sep;
    int         n;

    while (p < end && is_blank(*p)) {
        p++;
    }
    if (p == end || *p == '#' || *p == ';') {
        return;   /* blank or comment - not a line at all, never counted */
    }

    /* The key runs to the first separator or blank. Splitting on any of the
     * three keeps `host=1.2.3.4`, `host: 1.2.3.4` and `host 1.2.3.4` all
     * meaning the same thing. */
    sep = p;
    while (sep < end && *sep != '=' && *sep != ':' && !is_blank(*sep)) {
        sep++;
    }
    n = (int)(sep - p);
    if (n == 0 || n >= kKeyMax) {
        note_bad(s, line_no);
        return;
    }
    {
        int i;
        for (i = 0; i < n; i++) {
            key[i] = norm_key_char(p[i]);
        }
        key[n] = '\0';
    }

    /* Step over blanks, then at most one explicit separator, then blanks
     * again - so `host  =  1.2.3.4` works and `host = = 1.2.3.4` does not
     * (the second '=' becomes part of the value and fails validation, which
     * is the correct outcome for a line nobody meant to write). */
    p = sep;
    while (p < end && is_blank(*p)) {
        p++;
    }
    if (p < end && (*p == '=' || *p == ':')) {
        p++;
        while (p < end && is_blank(*p)) {
            p++;
        }
    }

    /* Trailing blanks are not part of the value. A trailing comment is not
     * stripped: '#' inside a value would then be unwritable, and no value
     * this file accepts contains one anyway, so `port = 5250 # default`
     * fails as a malformed line rather than half-working. */
    while (end > p && is_blank(*(end - 1))) {
        end--;
    }
    n = (int)(end - p);
    if (n <= 0 || n >= kValueMax) {
        note_bad(s, line_no);
        return;
    }
    {
        int i;
        for (i = 0; i < n; i++) {
            value[i] = p[i];
        }
        value[n] = '\0';
    }

    if (apply_pair(s, key, value)) {
        if (s->keys_set < 0xFFFFU) {
            s->keys_set++;
        }
    } else {
        note_bad(s, line_no);
    }
}

void n68_devsettings_parse(N68DevSettings *s, const char *text, long length)
{
    long           i = 0;
    long           start = 0;
    unsigned short line_no = 1;

    if (s == NULL || text == NULL || length <= 0) {
        return;
    }

    while (i <= length) {
        /* A CR, an LF, a CRLF, or the end of the buffer all end a line -
         * this file is written on a Mac and edited on macOS, and both
         * endings turn up, sometimes mixed inside one file after a round
         * trip. CRLF is consumed as ONE terminator so the line numbers in
         * first_bad_line still match what the human sees in their editor. */
        if (i == length || text[i] == '\r' || text[i] == '\n') {
            parse_line(s, text + start, text + i, line_no);
            if (i == length) {
                break;
            }
            if (text[i] == '\r' && i + 1 < length && text[i + 1] == '\n') {
                i++;
            }
            i++;
            start = i;
            if (line_no < 0xFFFFU) {
                line_no++;
            }
            continue;
        }
        i++;
    }
}
