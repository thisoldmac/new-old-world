/*
 * console_history.c - implementation of console_history.h.
 *
 * Slot arithmetic mirrors n68_console_ring.c: one monotonically increasing
 * counter, slot = index % capacity, no head/tail pair to keep consistent.
 *
 * bounded_strcpy rather than strncpy or snprintf: the first does not
 * guarantee a terminator and the second is forbidden outright on the 68K
 * target (numfmt.h - snprintf drags ~42 KB of newlib float formatting into
 * a 384 KB partition). Both guests compile THIS file, so it may only use
 * what both allow.
 */
#include "console_history.h"

#include <string.h>

static void bounded_strcpy(char *dst, int dst_cap, const char *src)
{
    int i = 0;

    if (dst_cap <= 0) {
        return;
    }
    if (src == NULL) {
        dst[0] = '\0';
        return;
    }
    while (i < dst_cap - 1 && src[i] != '\0') {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = '\0';
}

void console_history_init(ConsoleHistory *h)
{
    if (h == NULL) {
        return;
    }
    memset(h, 0, sizeof *h);
}

int console_history_count(const ConsoleHistory *h)
{
    if (h == NULL) {
        return 0;
    }
    if (h->total_pushed >= (unsigned long)kConsoleHistoryCapacity) {
        return kConsoleHistoryCapacity;
    }
    return (int)h->total_pushed;
}

/* The Nth-newest retained entry, N counted from 1. NULL if N is outside
 * what is retained - the single place the ring's index arithmetic lives. */
static const char *entry_from_newest(const ConsoleHistory *h, int n)
{
    unsigned long logical;

    if (n < 1 || n > console_history_count(h)) {
        return NULL;
    }
    logical = h->total_pushed - (unsigned long)n;
    return h->lines[logical % (unsigned long)kConsoleHistoryCapacity];
}

void console_history_push(ConsoleHistory *h, const char *line)
{
    const char *newest;

    if (h == NULL) {
        return;
    }

    /* Rewind first and unconditionally: Return means "done with this line"
     * whether or not the line was worth storing, so every early return
     * below still leaves the cursor at the fresh-line position. */
    h->depth = 0;
    h->pending[0] = '\0';

    if (line == NULL || line[0] == '\0') {
        return;
    }
    newest = entry_from_newest(h, 1);
    if (newest != NULL && strcmp(newest, line) == 0) {
        return;
    }

    bounded_strcpy(h->lines[h->total_pushed
                            % (unsigned long)kConsoleHistoryCapacity],
                   kConsoleHistoryLineCap, line);
    ++h->total_pushed;
}

const char *console_history_prev(ConsoleHistory *h, const char *current)
{
    const char *entry;

    if (h == NULL) {
        return NULL;
    }
    entry = entry_from_newest(h, h->depth + 1);
    if (entry == NULL) {
        return NULL;   /* nothing older - leave the field alone */
    }
    if (h->depth == 0) {
        /* First step of this walk: whatever is half-typed in the field is
         * about to be overwritten, so save it now. Later steps must NOT
         * re-save, or the second Up would capture the recalled entry as the
         * pending line and Down would never get back to what was typed. */
        bounded_strcpy(h->pending, kConsoleHistoryLineCap, current);
    }
    ++h->depth;
    return entry;
}

const char *console_history_next(ConsoleHistory *h)
{
    const char *entry;

    if (h == NULL || h->depth <= 0) {
        return NULL;   /* already at the fresh line - leave the field alone */
    }
    --h->depth;
    if (h->depth == 0) {
        return h->pending;   /* may be "" - that is a restore, not a no-op */
    }
    entry = entry_from_newest(h, h->depth);
    return entry != NULL ? entry : h->pending;
}
