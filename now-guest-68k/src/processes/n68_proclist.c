/* n68_proclist.c - implementation of n68_proclist.h. See that header for
 * the two rules this file exists to enforce (never truncate a row; never
 * emit an empty page that says more:true).
 *
 * No Toolbox call, no allocation, no printf family - numfmt.h's append
 * helpers for the same reason hello.c and ping.c use them (newlib's
 * vfprintf drags ~41 KB of float formatting into a 384 KB partition).
 */

#include "n68_proclist.h"

#include "numfmt.h"

#include <stddef.h>     /* NULL only - no allocation, no printf family */

/* One row is assembled here first and copied in only if it fits whole -
 * see the header. +1 for the NUL the appenders never write but the size
 * arithmetic is clearer with. */
enum { kRowScratch = NOW68K_PROCLIST_ROW_MAX + 1 };

/* Appends `s` with every byte that could break the host's decoder mapped
 * to '?': the two bytes that can escape a JSON string literal, the
 * control bytes JSON forbids raw, and every high-bit byte (MacRoman in,
 * UTF-8 expected out - see the header). Same bounds convention as
 * numfmt.h: 0 means it did not fit, *pos unspecified after that. */
static int append_json_text(char *buf, long cap, long *pos, const char *s)
{
    if (s == NULL) {
        return 1;
    }
    while (*s != '\0') {
        unsigned char c = (unsigned char)*s++;

        if (*pos < 0 || *pos >= cap) {
            return 0;
        }
        buf[(*pos)++] = (c == '"' || c == '\\' || c < 0x20 || c >= 0x80)
                            ? '?' : (char)c;
    }
    return 1;
}

/* A PSN half is an unsigned long and can have the top bit set, so it
 * cannot go through now68k_fmt_append_long (which would print it
 * negative, and the contract calls it an integer the host echoes back to
 * name a live process - a sign flip there names nothing). */
static int append_ulong(char *buf, long cap, long *pos, unsigned long value)
{
    char digits[12];
    int  n = 0;

    do {
        digits[n++] = (char)('0' + (value % 10UL));
        value /= 10UL;
    } while (value != 0UL && n < (int)sizeof digits);

    while (n > 0) {
        if (*pos < 0 || *pos >= cap) {
            return 0;
        }
        buf[(*pos)++] = digits[--n];
    }
    return 1;
}

static const char *kind_text(unsigned char kind)
{
    if (kind == kN68ProcKindBackground) {
        return "background";
    }
    if (kind == kN68ProcKindFinder) {
        return "finder";
    }
    /* Anything the gatherer could not classify is an application: the
     * contract's enum has no "unknown", and guessing "background" would
     * hide a real application from the human reading the list. */
    return "application";
}

/* Builds one row (with its leading comma when it is not the first) into
 * `buf`. Returns its length, or 0 if it did not fit kRowScratch - which
 * would mean NOW68K_PROCLIST_ROW_MAX is no longer the worst case, so it
 * is a refusal rather than a shortened row. test_proclist.c builds the
 * true worst case and fails if it approaches the bound. */
static long build_row(const N68ProcRow *r, int first, char *buf, long cap)
{
    long pos = 0;
    int ok = 1;
    long size_kb = r->size_kb < 0 ? 0 : r->size_kb;

    ok = ok && now68k_fmt_append_str(buf, cap, &pos,
                                     first ? "{\"name\":\"" : ",{\"name\":\"");
    ok = ok && append_json_text(buf, cap, &pos, r->name);
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "\",\"kind\":\"");
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, kind_text(r->kind));
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "\",\"code\":\"");
    ok = ok && append_json_text(buf, cap, &pos, r->code);
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "\",\"creator\":\"");
    ok = ok && append_json_text(buf, cap, &pos, r->creator);
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "\",\"sizeKB\":");
    ok = ok && now68k_fmt_append_long(buf, cap, &pos, size_kb);
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, ",\"front\":");
    ok = ok && now68k_fmt_append_str(buf, cap, &pos,
                                     r->front ? "true" : "false");
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, ",\"psnHigh\":");
    ok = ok && append_ulong(buf, cap, &pos, r->psn_high);
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, ",\"psnLow\":");
    ok = ok && append_ulong(buf, cap, &pos, r->psn_low);
    /* Emitted only when true. The contract makes the field optional and
     * absence means false, so every row but one saves 15 bytes of a 4 KB
     * frame - which is rows per page on a machine where the page size is
     * derived from the frame, not chosen. */
    if (r->is_self) {
        ok = ok && now68k_fmt_append_str(buf, cap, &pos, ",\"isSelf\":true");
    }
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "}");

    if (!ok || pos <= 0 || pos > cap) {
        return 0;
    }
    return pos;
}

long n68_proclist_build(long id, long cursor,
                        const N68ProcRow *rows, long row_count,
                        char *out, long cap,
                        long *next_cursor, int *more)
{
    char scratch[kRowScratch];
    long pos = 0;
    long emitted = 0;
    long index;
    int ok = 1;
    int has_more = 0;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    if (rows == NULL) {
        row_count = 0;
    }
    if (row_count < 0) {
        row_count = 0;
    }
    if (cursor < 1) {
        cursor = 1;   /* absent or nonsensical: start at the beginning */
    }

    ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                     "{\"type\":\"process.listing\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, cap, &pos, id);
    ok = ok && now68k_fmt_append_str(out, cap, &pos, ",\"processes\":[");
    if (!ok) {
        out[0] = '\0';
        return 0;   /* cap cannot even hold the envelope */
    }

    for (index = cursor; index <= row_count; ++index) {
        long n;
        long i;

        if (emitted >= NOW68K_PROCLIST_MAX_ROWS) {
            has_more = 1;
            break;
        }
        n = build_row(&rows[index - 1], emitted == 0, scratch,
                      (long)sizeof scratch);
        if (n <= 0) {
            /* The row itself outgrew NOW68K_PROCLIST_ROW_MAX. Refusing
             * the whole page is the only honest answer: skipping the row
             * would silently hide a running process, and emitting a
             * partial one costs the page anyway. */
            out[0] = '\0';
            return 0;
        }
        if (pos + n + NOW68K_PROCLIST_TAIL_MAX > cap) {
            has_more = 1;   /* this row starts the next page */
            break;
        }
        for (i = 0; i < n; ++i) {
            out[pos + i] = scratch[i];
        }
        pos += n;
        ++emitted;
    }

    /* Rows were waiting and not one of them fit: an empty page with
     * more:true would make the host ask again with the same cursor and
     * get the same answer, forever. Refuse instead - and the static
     * assert at the send site (wire68.c) is what keeps this unreachable
     * in the shipping build. */
    if (emitted == 0 && has_more) {
        out[0] = '\0';
        return 0;
    }

    ok = ok && now68k_fmt_append_str(out, cap, &pos, "],\"more\":");
    ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                     has_more ? "true" : "false");
    ok = ok && now68k_fmt_append_str(out, cap, &pos, ",\"cursor\":");
    ok = ok && now68k_fmt_append_long(out, cap, &pos, cursor + emitted);
    ok = ok && now68k_fmt_append_str(out, cap, &pos, "}");
    if (!ok || pos <= 0 || pos >= cap) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';

    if (next_cursor != NULL) {
        *next_cursor = cursor + emitted;
    }
    if (more != NULL) {
        *more = has_more;
    }
    return pos;
}

/* ---- the same rows, as the `ps` command -------------------------------- */

/* One [name, detail] pair. `detail` reads "application, 512 KB, front" -
 * the same sentence the PowerPC guest's ps builds (now-guest-ppc/src/commands/commands.c,
 * now_process_gather), because the host console renders both guests with
 * one renderer and a person should not have to know which machine they
 * are looking at to read a column. */
static long build_ps_row(const N68ProcRow *r, int first, char *buf, long cap)
{
    long pos = 0;
    int ok = 1;
    long size_kb = r->size_kb < 0 ? 0 : r->size_kb;

    ok = ok && now68k_fmt_append_str(buf, cap, &pos, first ? "[\"" : ",[\"");
    /* A process with no name is a row a human cannot act on; saying so
     * beats an empty cell that reads like a rendering bug. */
    ok = ok && append_json_text(buf, cap, &pos,
                                r->name[0] != '\0' ? r->name : "(unnamed)");
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "\",\"");
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, kind_text(r->kind));
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, ", ");
    ok = ok && now68k_fmt_append_long(buf, cap, &pos, size_kb);
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, " KB");
    if (r->front) {
        ok = ok && now68k_fmt_append_str(buf, cap, &pos, ", front");
    }
    /* The same fact the wire's isSelf carries, in the sentence a person
     * reads: which of these rows is the application answering you. Both
     * guests' ps say "self" so the host console's one renderer does not
     * make a person work out which machine they are looking at. */
    if (r->is_self) {
        ok = ok && now68k_fmt_append_str(buf, cap, &pos, ", self");
    }
    ok = ok && now68k_fmt_append_str(buf, cap, &pos, "\"]");

    if (!ok || pos <= 0 || pos > cap) {
        return 0;
    }
    return pos;
}

long n68_proclist_render_ps(long id, const N68ProcRow *rows, long row_count,
                            char *out, long cap)
{
    char scratch[NOW68K_PS_ROW_MAX + 1];
    long pos = 0;
    long emitted = 0;
    long index;
    int ok = 1;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';
    if (rows == NULL || row_count < 0) {
        row_count = 0;
    }

    ok = ok && now68k_fmt_append_str(
                   out, cap, &pos,
                   "{\"type\":\"command.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, cap, &pos, id);
    ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                     ",\"ok\":true,\"output\":{\"ps\":[");
    if (!ok) {
        out[0] = '\0';
        return 0;   /* cap cannot even hold the envelope */
    }

    for (index = 0; index < row_count; ++index) {
        long n = build_ps_row(&rows[index], emitted == 0, scratch,
                              (long)sizeof scratch);

        if (n <= 0) {
            /* The row outgrew NOW68K_PS_ROW_MAX, so the bound is no longer
             * the worst case. Stop here and let the note row below say how
             * many are missing rather than emit a half-row. */
            break;
        }
        /* Room for this row AND for the note that would have to follow it:
         * a reply that spends its last bytes on one more process and then
         * cannot say it truncated is the failure this reserves against. */
        if (pos + n + NOW68K_PS_NOTE_MAX + NOW68K_PS_TAIL_MAX > cap) {
            break;
        }
        {
            long i;
            for (i = 0; i < n; ++i) {
                out[pos + i] = scratch[i];
            }
        }
        pos += n;
        ++emitted;
    }

    if (emitted < row_count) {
        ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                         emitted == 0 ? "[\"...\",\""
                                                      : ",[\"...\",\"");
        ok = ok && now68k_fmt_append_long(out, cap, &pos, row_count - emitted);
        ok = ok && now68k_fmt_append_str(out, cap, &pos,
                                         " more not shown\"]");
    }
    ok = ok && now68k_fmt_append_str(out, cap, &pos, "]}}");
    if (!ok || pos <= 0 || pos >= cap) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    return pos;
}
