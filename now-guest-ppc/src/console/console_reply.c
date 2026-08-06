#include "console_reply.h"

#include "json.h"

#include <stdio.h>
#include <string.h>

enum {
    kLineCap = kConsoleMaxCols,
    kRowCap = 320,
    kFieldCap = 160,
    kKeyCap = 48
};

static const char *skip_space(const char *p)
{
    while (*p == ' ' || *p == '\t' || *p == '\r' || *p == '\n') {
        ++p;
    }
    return p;
}

/* The output object's FIRST key and the array behind it, or NULL.
 *
 * Read out of the reply rather than assumed from the verb the caller
 * typed: `now_command_run` picks the key, and a renderer that recomposed
 * it from the typed word would be a second opinion about the name of a
 * thing the reply already states. Two of them would disagree the first
 * time a verb answered under another key. */
static const char *output_rows(const char *json, char *key, long key_cap)
{
    const char *p = now_json_value(json, "output");
    long n = 0;

    if (p == NULL || *p != '{') {
        return NULL;
    }
    p = skip_space(p + 1);
    if (*p != '"') {
        return NULL;
    }
    ++p;
    while (*p != '\0' && *p != '"') {
        if (n + 1 < key_cap) {
            key[n++] = *p;
        }
        ++p;
    }
    key[n] = '\0';
    if (*p != '"') {
        return NULL;
    }
    p = skip_space(p + 1);
    if (*p != ':') {
        return NULL;
    }
    p = skip_space(p + 1);
    return (*p == '[') ? p + 1 : NULL;
}

int console_reply_render(const char *json, ConsoleEmit emit, void *ctx)
{
    char line[kLineCap];
    char key[kKeyCap];

    if (emit == NULL) {
        return kConsoleReplyMalformed;
    }
    if (json == NULL || json[0] == '\0'
        || !now_json_type_is(json, "command.result")) {
        emit(ctx, "command failed");
        return kConsoleReplyMalformed;
    }

    /* A refusal has always rendered correctly and keeps its wording: the
       guest's own sentence, alone. The code beside it is a slug for a
       machine and adding it here would change what a person reads for the
       one case that was never broken. */
    if (!now_json_find_bool(json, "ok", 0)) {
        char message[kFieldCap];

        if (now_json_find_text(json, "message", message, sizeof message)) {
            snprintf(line, sizeof line, "%.120s", message);
            emit(ctx, line);
        } else {
            emit(ctx, "command failed");
        }
        return kConsoleReplyRefused;
    }

    {
        const char *p = output_rows(json, key, sizeof key);
        char row[kRowCap];
        int count = 0;

        if (p == NULL) {
            /* Says what it cannot do and NAMES the verb, because the
               alternative was "command failed" - a claim of failure about
               a command that succeeded. `observe` and its relatives answer
               with an object of references; there is nothing a console
               line can carry, and pretending otherwise would be worse
               than admitting it. */
            snprintf(line, sizeof line,
                     "  (answered, but not as a table this console can show)");
            emit(ctx, line);
            return kConsoleReplyOpaque;
        }
        while ((p = now_json_next_array(p, row, sizeof row)) != NULL) {
            char label[kFieldCap];
            char value[kFieldCap];

            if (!now_json_array_string(row, 0, label, sizeof label)) {
                continue;
            }
            if (!now_json_array_string(row, 1, value, sizeof value)) {
                value[0] = '\0';
            }
            /* The census page's column, so two tables typed at one console
               line up rather than each choosing its own gutter. */
            snprintf(line, sizeof line, "  %-24.31s %.90s", label, value);
            emit(ctx, line);
            ++count;
        }
        if (count == 0) {
            /* An empty table is an answer - `putstat` on a Mac that has
               received nothing is all zeroes, and a verb whose table is
               genuinely empty has still run. Saying so beats a blank. */
            snprintf(line, sizeof line, "  %.60s: nothing to report", key);
            emit(ctx, line);
        }
        return kConsoleReplyRows;
    }
}
