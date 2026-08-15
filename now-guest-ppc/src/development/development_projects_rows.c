#include "development_projects_rows.h"

#include <stdio.h>
#include <string.h>

#include "json.h"

int dev_projects_record(char *out, long cap, const DevProjectRow *row)
{
    int written;
    if (out == NULL || cap <= 0 || row == NULL || row->id[0] == '\0') return 0;
    written = snprintf(out, (size_t)cap, "%s|%s", row->id, row->name);
    return written > 0 && written < cap;
}

/* Every piece of the answer is appended through here, so the "does it
   fit" decision is made once: a truncated JSON object on the wire reads
   as a malformed reply from a broken guest, where a refused page reads
   as what it is. Returns -1 when the piece does not fit. */
static long append(char *out, long cap, long pos, const char *text)
{
    long length;
    if (pos < 0 || pos >= cap) return -1;
    length = (long)strlen(text);
    if (length >= cap - pos) return -1;
    memcpy(out + pos, text, (size_t)length + 1);
    return pos + length;
}

long dev_projects_reply(char *out, long cap, long id,
                        const DevProjectRow *rows, int count,
                        long next, const char *active_id)
{
    char piece[(kDevProjectsIDCap + kDevProjectsNameCap + 2) * 2 + 64];
    long pos = 0;
    int i;
    int has_active = active_id != NULL && active_id[0] != '\0';
    if (out == NULL || cap <= 0 || count < 0
        || (count > 0 && rows == NULL)) return 0;
    snprintf(piece, sizeof piece,
        "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
        "\"output\":{\"development-project\":[", id);
    pos = append(out, cap, pos, piece);
    for (i = 0; i < count && pos >= 0; ++i) {
        char record[kDevProjectsIDCap + kDevProjectsNameCap + 2];
        char escaped[(kDevProjectsIDCap + kDevProjectsNameCap + 2) * 2 + 4];
        if (!dev_projects_record(record, sizeof record, &rows[i])) return 0;
        now_json_escape(record, escaped, sizeof escaped);
        snprintf(piece, sizeof piece, "%s[\"Project\",\"%s\"]",
                 i ? "," : "", escaped);
        pos = append(out, cap, pos, piece);
    }
    /* Which project this Mac is working on is part of the answer: the
       host asks the guest what it has, and "and this is the one it has
       chosen" is the same question. Absent when nothing is chosen. */
    if (has_active && pos >= 0) {
        char escaped[kDevProjectsIDCap * 2 + 4];
        now_json_escape(active_id, escaped, sizeof escaped);
        snprintf(piece, sizeof piece, "%s[\"Active\",\"%s\"]",
                 count ? "," : "", escaped);
        pos = append(out, cap, pos, piece);
    }
    if (pos >= 0) {
        snprintf(piece, sizeof piece, "%s[\"Next\",\"%ld\"]]}}",
                 (count || has_active) ? "," : "", next);
        pos = append(out, cap, pos, piece);
    }
    if (pos < 0) {
        out[0] = '\0';
        return 0;
    }
    return pos;
}
