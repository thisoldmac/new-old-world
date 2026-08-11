#include "gestalt_json.h"

#include <stdio.h>
#include <string.h>

/* Bytes held back from the caller's cap so the tail — the `]` closing an
   open group, the truncation notice, and the two closing braces — is always
   writable. Worst case is 67 bytes; the rest is headroom for the notice's
   wording changing. */
#define kTailReserve 96

/* A bounded writer. Every byte in the reply goes through it, which is the
   whole discipline: there is no second path that writes without asking. */
typedef struct {
    char *out;
    long  cap;   /* the bound; out[cap - 1] is reserved for the NUL */
    long  pos;
    int   full;  /* a write did not fit — every later write is a no-op */
} Sink;

static void put(Sink *s, char c)
{
    if (s->full) {
        return;
    }
    if (s->pos + 1 >= s->cap) {
        s->full = 1;
        return;
    }
    s->out[s->pos++] = c;
}

static void put_text(Sink *s, const char *t)
{
    for (; *t != '\0'; ++t) {
        put(s, *t);
        if (s->full) {
            return;
        }
    }
}

/* A JSON string body. The escape and the character it protects can land on
   opposite sides of the bound; the caller's row-level rollback is what makes
   that safe, so this does not try to be atomic itself. */
static void put_escaped(Sink *s, const char *t)
{
    for (; *t != '\0'; ++t) {
        if (*t == '"' || *t == '\\') {
            put(s, '\\');
        }
        put(s, *t);
        if (s->full) {
            return;
        }
    }
}

int now_gestalt_result_json(long id, const GestaltRow *rows, int count,
                            const char *const *groups, char *out, long cap)
{
    Sink s;
    char head[96];
    int g, i;
    int omitted = 0;
    int group_open = 0;
    int first_group = 1;

    if (out == NULL || cap <= 0) {
        return count > 0 ? count : 0;
    }
    out[0] = '\0';
    if (cap < kGestaltJsonMinCap || rows == NULL) {
        return count > 0 ? count : 0;
    }

    /* Rows are written against the reserved bound, not the caller's. */
    s.out = out;
    s.cap = cap - kTailReserve;
    s.pos = 0;
    s.full = 0;

    snprintf(head, sizeof head,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{", id);
    put_text(&s, head);

    for (g = 0; groups != NULL && groups[g] != NULL; ++g) {
        for (i = 0; i < count; ++i) {
            long save_pos;
            int save_open, save_first;

            if (strcmp(rows[i].group, groups[g]) != 0) {
                continue;
            }
            if (s.full) {
                ++omitted;      /* still counted, so the notice is honest */
                continue;
            }

            save_pos = s.pos;
            save_open = group_open;
            save_first = first_group;

            if (group_open) {
                put(&s, ',');
            } else {
                if (!first_group) {
                    put(&s, ',');
                }
                put(&s, '"');
                put_escaped(&s, groups[g]);
                put_text(&s, "\":[");
            }
            put_text(&s, "[\"");
            put_escaped(&s, rows[i].label);
            put_text(&s, "\",\"");
            put_escaped(&s, rows[i].value);
            put_text(&s, "\"]");

            if (s.full) {
                /* A partial row is not a row. Rewind to before the group
                   header this row may have opened, and stop. */
                s.pos = save_pos;
                group_open = save_open;
                first_group = save_first;
                ++omitted;
                continue;
            }
            group_open = 1;
            first_group = 0;
        }
        /* This `]` is a write like any other and can be the one that hits
           the bound. Clearing group_open regardless of whether it landed
           leaves an array open that nothing closes, and the tail below
           cannot know: the reply reads `...]],"notice"` with one bracket
           missing. Only the successful close ends the group. */
        if (group_open && !s.full) {
            put(&s, ']');
            if (!s.full) {
                group_open = 0;
            }
        }
    }

    /* The reserve, now spent: the tail may reach the caller's real cap.
       Clearing `full` is safe because nothing below it is a row — this is
       the fixed-size ending the reserve was set aside for. */
    s.cap = cap;
    s.full = 0;

    if (group_open) {
        put(&s, ']');
    }
    if (omitted > 0) {
        char note[96];

        if (!first_group) {
            put(&s, ',');
        }
        snprintf(note, sizeof note,
                 "\"notice\":[[\"truncated\",\"%d rows omitted - reply "
                 "buffer full\"]]", omitted);
        put_text(&s, note);
    }
    put_text(&s, "}}");
    s.out[s.pos] = '\0';
    return omitted;
}
