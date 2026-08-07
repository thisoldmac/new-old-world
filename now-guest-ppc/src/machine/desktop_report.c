#include "desktop.h"
#include "json.h"

#include <stdio.h>
#include <string.h>

/* The `desktop` reply's serialization. Pure C - no Toolbox - so the
   native test compiles this file with the host cc and the wire shape is
   provable off the machine, the way census_report.c is. */

const char *now_desktop_source_name(DesktopSource source)
{
    switch (source) {
    case kDesktopSourcePattern: return "pattern";
    case kDesktopSourcePicture: return "picture";
    case kDesktopSourceUnknown: return "unknown";
    }
    return "unknown";
}

static void copy_capped(char *dst, long cap, const char *src)
{
    long n;

    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    n = (long)strlen(src);
    if (n > cap - 1) {
        n = cap - 1;
    }
    memcpy(dst, src, (size_t)n);
    dst[n] = '\0';
}

int now_desktop_add_row(DesktopAnswer *answer, const char *name,
                        const char *raw, const char *note)
{
    DesktopRow *row;

    if (answer->count >= kDesktopRowMax) {
        /* Dropped, and said so. A page that loses a row silently reads as
           a machine that did not have it. */
        copy_capped(answer->note, (long)sizeof answer->note,
                    "rows dropped - answer full");
        return -1;
    }
    row = &answer->rows[answer->count];
    copy_capped(row->name, (long)sizeof row->name, name);
    copy_capped(row->raw, (long)sizeof row->raw, raw);
    copy_capped(row->note, (long)sizeof row->note, note);
    answer->count++;
    return 0;
}

void now_desktop_hex(const unsigned char *bytes, long len, char *out, long cap)
{
    static const char kDigits[] = "0123456789abcdef";
    long i;
    long pos = 0;

    for (i = 0; i < len; i++) {
        if (pos + 2 >= cap) {
            break;
        }
        out[pos++] = kDigits[(bytes[i] >> 4) & 0x0F];
        out[pos++] = kDigits[bytes[i] & 0x0F];
    }
    out[pos] = '\0';
}

/* Append `text` at *pos; nonzero and untouched *pos on overflow, so one
   check at the end suffices. */
static int overflowed(char *out, long cap, long *pos, const char *text)
{
    long n = (long)strlen(text);

    if (*pos + n >= cap) {
        return 1;
    }
    memcpy(out + *pos, text, (size_t)n);
    *pos += n;
    out[*pos] = '\0';
    return 0;
}

long now_desktop_result_json(long id, const DesktopAnswer *answer,
                             char *out, long cap)
{
    char scratch[2 * kDesktopRowRawCap + 32];
    char esc[2 * kDesktopRowRawCap + 4];
    long pos = 0;
    int i;

    if (answer->count > kDesktopRowMax) {
        return -1;              /* an answer that breaks its own cap is a bug */
    }
    snprintf(scratch, sizeof scratch,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"desktop\":[", id);
    if (overflowed(out, cap, &pos, scratch)) {
        return -1;
    }
    for (i = 0; i < answer->count; i++) {
        const DesktopRow *row = &answer->rows[i];
        const char *fields[3];
        int f;

        fields[0] = row->name;
        fields[1] = row->raw;
        fields[2] = row->note;
        if (overflowed(out, cap, &pos, i > 0 ? ",[" : "[")) {
            return -1;
        }
        for (f = 0; f < 3; f++) {
            now_json_escape(fields[f], esc, (long)sizeof esc);
            snprintf(scratch, sizeof scratch, "%s\"%s\"", f > 0 ? "," : "", esc);
            if (overflowed(out, cap, &pos, scratch)) {
                return -1;
            }
        }
        if (overflowed(out, cap, &pos, "]")) {
            return -1;
        }
    }
    /* The typed facts ride BESIDE the rows, not inside them. The rows are
       for a person reading the console; a renderer needs to know whether a
       pattern is even visible without parsing prose. */
    snprintf(scratch, sizeof scratch,
             "],\"source\":\"%s\",\"hasPattern\":%s,\"hasPicture\":%s,"
             "\"patternBytes\":%ld,\"patternCarried\":%ld",
             now_desktop_source_name(answer->source),
             answer->has_pattern ? "true" : "false",
             answer->has_picture ? "true" : "false",
             answer->pattern_bytes, answer->pattern_carried);
    if (overflowed(out, cap, &pos, scratch)) {
        return -1;
    }
    if (answer->note[0] != '\0') {
        now_json_escape(answer->note, esc, (long)sizeof esc);
        snprintf(scratch, sizeof scratch, ",\"note\":\"%s\"", esc);
        if (overflowed(out, cap, &pos, scratch)) {
            return -1;
        }
    }
    if (overflowed(out, cap, &pos, "}}")) {
        return -1;
    }
    return pos;
}
