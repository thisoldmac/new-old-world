/*
 * n68_shot.c - implementation of n68_shot.h. Read that header first: it
 * carries what the four timing numbers mean and, in particular, that
 * encode_ms is a difference of two passes rather than a direct reading.
 *
 * STATIC BUDGET: none. No BSS, no allocation, no printf family.
 */
#include "n68_shot.h"

#include "numfmt.h"

#include <string.h>

void n68_shot_args_init(N68ShotArgs *a)
{
    if (a == NULL) {
        return;
    }
    a->depth = kN68ShotDepth;
    a->save = 1;
}

/* Token-at-a-time rather than a parser: the whole grammar is two flags,
 * and the rule that an unknown token is ignored means there is nothing to
 * recover from and no error to report. */
static long token_at(const char *line, long from, char *out, long cap)
{
    long i = from;
    long n = 0;

    while (line[i] == ' ' || line[i] == '\t') {
        ++i;
    }
    while (line[i] != '\0' && line[i] != ' ' && line[i] != '\t') {
        if (n < cap - 1) {
            out[n++] = line[i];
        }
        ++i;
    }
    out[n] = '\0';
    return i;
}

static long token_long(const char *t, long fallback)
{
    long v = 0;
    long i = 0;

    if (t[0] == '\0') {
        return fallback;
    }
    for (i = 0; t[i] != '\0'; ++i) {
        if (t[i] < '0' || t[i] > '9') {
            return fallback;
        }
        v = v * 10 + (t[i] - '0');
        if (v > 32767) {
            return fallback;
        }
    }
    return v;
}

void n68_shot_args_parse(const char *line, N68ShotArgs *a)
{
    char tok[24];
    long i = 0;

    n68_shot_args_init(a);
    if (line == NULL) {
        return;
    }
    for (;;) {
        i = token_at(line, i, tok, (long)sizeof tok);
        if (tok[0] == '\0') {
            return;
        }
        if (strcmp(tok, "--no-save") == 0 || strcmp(tok, "--save=false") == 0) {
            a->save = 0;
        } else if (strcmp(tok, "--save") == 0
                   || strcmp(tok, "--save=true") == 0) {
            a->save = 1;
        } else if (strcmp(tok, "--depth") == 0) {
            i = token_at(line, i, tok, (long)sizeof tok);
            a->depth = token_long(tok, a->depth);
        }
        /* Anything else: ignored on purpose. See the header. */
    }
}

/* ---- bands ---------------------------------------------------------------- */

long n68_shot_band_count(long height, long rows)
{
    if (rows <= 0) {
        rows = 1;
    }
    if (height <= 0) {
        return 0;
    }
    return (height + rows - 1) / rows;
}

long n68_shot_band_top(long height, long rows, long i)
{
    long top;

    if (rows <= 0) {
        rows = 1;
    }
    if (i < 0 || i >= n68_shot_band_count(height, rows)) {
        return 0;
    }
    top = i * rows;
    return top;
}

long n68_shot_band_rows(long height, long rows, long i)
{
    long top;

    if (rows <= 0) {
        rows = 1;
    }
    if (i < 0 || i >= n68_shot_band_count(height, rows)) {
        return 0;
    }
    top = i * rows;
    /* The short last band. A capture that dropped the remainder would look
     * correct on the one display whose height happens to divide. */
    return (top + rows <= height) ? rows : height - top;
}

/* ---- the name ------------------------------------------------------------- */

static long append_2(char *out, long cap, long *pos, long v)
{
    if (v < 0) {
        v = 0;
    }
    v %= 100;
    if (*pos + 2 > cap - 1) {
        return 0;
    }
    out[(*pos)++] = (char)('0' + v / 10);
    out[(*pos)++] = (char)('0' + v % 10);
    return 1;
}

long n68_shot_name(char *out, long cap, long year, long month, long day,
                   long hour, long minute, long second,
                   unsigned long ticks, long attempt)
{
    long pos = 0;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';

    if (attempt > 0) {
        /* Same-second collision. Ticks are unique enough, and short: the
         * PowerPC guest does exactly this and the two names are meant to
         * be recognisable as the same product's. */
        if (!now68k_fmt_append_str(out, cap - 1, &pos, "Screenshot ")
            || !now68k_fmt_append_long(out, cap - 1, &pos, (long)ticks)) {
            out[0] = '\0';
            return 0;
        }
        out[pos] = '\0';
        return pos;
    }

    if (year < 0) {
        year = 0;
    }
    year %= 10000;
    if (!now68k_fmt_append_str(out, cap - 1, &pos, "Screenshot ")) {
        out[0] = '\0';
        return 0;
    }
    if (!append_2(out, cap, &pos, year / 100)
        || !append_2(out, cap, &pos, year)
        || pos + 1 > cap - 1) {
        out[0] = '\0';
        return 0;
    }
    out[pos++] = '-';
    if (!append_2(out, cap, &pos, month) || pos + 1 > cap - 1) {
        out[0] = '\0';
        return 0;
    }
    out[pos++] = '-';
    if (!append_2(out, cap, &pos, day) || pos + 1 > cap - 1) {
        out[0] = '\0';
        return 0;
    }
    out[pos++] = ' ';
    if (!append_2(out, cap, &pos, hour) || pos + 1 > cap - 1) {
        out[0] = '\0';
        return 0;
    }
    out[pos++] = '.';
    if (!append_2(out, cap, &pos, minute) || pos + 1 > cap - 1) {
        out[0] = '\0';
        return 0;
    }
    out[pos++] = '.';
    if (!append_2(out, cap, &pos, second)) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

/* ---- the ratio ------------------------------------------------------------ */

long n68_shot_ratio(char *out, long cap, long raw_bytes, long packed_bytes)
{
    long tenths;
    long pos = 0;

    if (out == NULL || cap <= 0) {
        return 0;
    }
    out[0] = '\0';

    if (raw_bytes <= 0 || packed_bytes <= 0 || packed_bytes >= raw_bytes) {
        /* PackBits can expand incompressible data, and a sub-1.0 ratio is
         * a real outcome - but it is one for the bytes columns to show,
         * not for this five-character string to try to explain. */
        tenths = 10;
    } else {
        /* Rounded to a tenth, in longs: raw/packed * 10, +1/2. No floats
         * anywhere in this tree (numfmt.h's comment says why). raw is at
         * most a 300 KB frame, so raw * 20 stays far inside 32 bits. */
        tenths = (raw_bytes * 20 / packed_bytes + 1) / 2;
    }
    if (!now68k_fmt_append_long(out, cap - 1, &pos, tenths / 10)
        || pos + 1 > cap - 1) {
        out[0] = '\0';
        return 0;
    }
    out[pos++] = '.';
    if (!now68k_fmt_append_long(out, cap - 1, &pos, tenths % 10)
        || !now68k_fmt_append_str(out, cap - 1, &pos, ":1")) {
        out[0] = '\0';
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

/* ---- the two rows --------------------------------------------------------- */

static int append_ms(char *out, long cap, long *pos, const char *label,
                     long ms)
{
    return now68k_fmt_append_str(out, cap, pos, label)
           && now68k_fmt_append_long(out, cap, pos, ms)
           && now68k_fmt_append_str(out, cap, pos, " ms");
}

void n68_shot_summary(const N68ShotStats *s, N68CmdResult *res)
{
    char what[kN68CmdTextCap];
    char cost[kN68CmdStateCap];
    char ratio[16];
    long pos = 0;

    if (s == NULL || res == NULL) {
        return;
    }
    what[0] = '\0';
    cost[0] = '\0';

    (void)n68_shot_ratio(ratio, (long)sizeof ratio, s->raw_bytes,
                         s->pict_bytes);

    /* Row one: the geometry, where it went, and the two numbers a person
     * actually wants - what it cost on disk and what packing bought. */
    (void)(now68k_fmt_append_long(what, (long)sizeof what - 1, &pos, s->width)
           && now68k_fmt_append_str(what, (long)sizeof what - 1, &pos, "x")
           && now68k_fmt_append_long(what, (long)sizeof what - 1, &pos,
                                     s->height)
           && now68k_fmt_append_str(what, (long)sizeof what - 1, &pos, "x")
           && now68k_fmt_append_long(what, (long)sizeof what - 1, &pos,
                                     s->depth)
           && now68k_fmt_append_str(what, (long)sizeof what - 1, &pos, ", ")
           && now68k_fmt_append_long(what, (long)sizeof what - 1, &pos,
                                     s->pict_bytes)
           && now68k_fmt_append_str(what, (long)sizeof what - 1, &pos,
                                    " bytes, ")
           && now68k_fmt_append_str(what, (long)sizeof what - 1, &pos, ratio)
           && now68k_fmt_append_str(what, (long)sizeof what - 1, &pos,
                                    s->saved_name[0] != '\0'
                                        ? " -> " : " (not saved)")
           && (s->saved_name[0] == '\0'
               || now68k_fmt_append_str(what, (long)sizeof what - 1, &pos,
                                        s->saved_name)));
    what[pos > 0 ? pos : 0] = '\0';

    /* Row two: the cost breakdown. "pack" rather than "encode" because
     * that is what QuickDraw is doing - PackBits per row inside CopyBits -
     * and a reader comparing this against vprobe's CopyBits row needs to
     * see that the same call produced both. */
    pos = 0;
    (void)(append_ms(cost, (long)sizeof cost - 1, &pos, "read ", s->read_ms)
           && append_ms(cost, (long)sizeof cost - 1, &pos, ", pack ",
                        s->encode_ms)
           && append_ms(cost, (long)sizeof cost - 1, &pos, ", write ",
                        s->write_ms));
    cost[pos > 0 ? pos : 0] = '\0';

    n68_cmdresult_set_ok2(res, "screenshot", "Shot", what, "Cost", cost);
}
