/*
 * n68_cmdresult.c - the two renderers of one N68CmdResult (see the header
 * for why they live in the same file).
 *
 * The JSON half moved here verbatim from commands68.c's append_envelope /
 * finish_error / finish_ok_row1 / finish_ok_row2, which are now one
 * function with a row count. The MacRoman escape table and
 * now68k_json_append_escaped moved with it, because they exist only to
 * serve the JSON renderer and nothing in commands68.c calls them any
 * more. The escaper is published (n68_cmdresult.h) now that the file
 * sender needs the same one for a filename a person chose.
 *
 * This file owns no BSS and calls nothing outside numfmt.h and <string.h>.
 * In particular it does NOT call log.h: a render that does not fit returns
 * 0, and the caller - which knows which command it was running - logs it.
 * That is what lets guest68k/tests/test_cmdresult.c link this file alone.
 */
#include "n68_cmdresult.h"

#include "numfmt.h"

#include <string.h>

/* ---- small bounded copies ------------------------------------------------ */

static void bounded_strcpy(char *dst, long dst_cap, const char *src)
{
    long i = 0;

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

void n68_cmdresult_init(N68CmdResult *r)
{
    if (r == NULL) {
        return;
    }
    memset(r, 0, sizeof *r);
}

void n68_cmdresult_set_error(N68CmdResult *r, const char *code,
                              const char *message)
{
    if (r == NULL) {
        return;
    }
    n68_cmdresult_init(r);
    r->ok = 0;
    bounded_strcpy(r->code, (long)sizeof r->code, code);
    bounded_strcpy(r->text, (long)sizeof r->text, message);
}

void n68_cmdresult_set_ok1(N68CmdResult *r, const char *key,
                            const char *label, const char *value)
{
    if (r == NULL) {
        return;
    }
    n68_cmdresult_init(r);
    r->ok = 1;
    bounded_strcpy(r->key,   (long)sizeof r->key,   key);
    bounded_strcpy(r->label, (long)sizeof r->label, label);
    bounded_strcpy(r->text,  (long)sizeof r->text,  value);
}

void n68_cmdresult_set_ok2(N68CmdResult *r, const char *key,
                            const char *label1, const char *value1,
                            const char *label2, const char *value2)
{
    if (r == NULL) {
        return;
    }
    n68_cmdresult_set_ok1(r, key, label1, value1);
    bounded_strcpy(r->label2, (long)sizeof r->label2, label2);
    bounded_strcpy(r->state,  (long)sizeof r->state,  value2);
}

/* ---- JSON string safety --------------------------------------------------- */

/* MacRoman 0x80..0xFF to Unicode, read the other way from the PowerPC
 * guest's own copy (now/guest/src/json.c, static k_macroman_high[]) -
 * reproduced rather than shared because that file lives in a different
 * repo/build this client cannot include. Used by now68k_json_append_escaped()
 * below for bytes >= 0x80: a process or HFS name on this platform routinely
 * carries one of these (an accented letter, a trademark sign), and it is
 * ordinary text here, not corruption. */
static const unsigned short k_macroman_high[128] = {
    0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1,
    0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
    0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3,
    0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
    0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF,
    0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
    0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211,
    0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
    0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB,
    0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
    0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA,
    0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
    0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1,
    0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
    0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC,
    0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7
};

/* Appends `s` into buf[*pos, cap) as the BODY of a JSON string (the caller
 * writes the surrounding quotes) - real escaping, not a sanitizer that
 * mangles bytes to '?'. '?' corrupts a message that legitimately quoted a
 * name ("nothing named ?NetPresenz? is running"), and a raw high-bit byte
 * inside a JSON string is invalid UTF-8, which a spec-correct host parser
 * rejects outright - the whole frame is discarded and the caller's command
 * blocks until the 75 s idle timeout, not just that one field.
 *
 * The escaping mirrors the PowerPC guest's now_json_escape():
 *   - '"' and '\\'      -> backslash-escaped, so the literal cannot reopen
 *                          or corrupt.
 *   - < 0x20, or 0x7F    -> \u00XX. A raw control byte would corrupt the
 *                          control FRAME (text, newline-sensitive), not
 *                          just the JSON.
 *   - >= 0x80            -> \u escaped from its Unicode code point via
 *                          k_macroman_high, e.g. 0x8E (e-acute) becomes
 *                          the six bytes é. Transliterating to '?'
 *                          would make an
 *                          accented name and its plain-ASCII near-miss
 *                          collide, which is worse for a caller matching
 *                          replies against what it asked for than a few
 *                          extra bytes on the wire.
 *
 * Bounded exactly like now68k_fmt_append_str: stops and returns 0 the
 * moment the next escaped piece would not fit, so no half-escaped sequence
 * is ever left in `buf`; no NUL is written here, matching numfmt.h's append
 * contract (the caller terminates once the whole chain succeeds). No
 * snprintf - hex digits are built by hand (standing rule: no printf family
 * in this tree). */
int now68k_json_append_escaped(char *buf, long cap, long *pos, const char *s)
{
    static const char kHex[] = "0123456789ABCDEF";

    if (*pos < 0) {
        return 0;
    }
    for (; *s != '\0'; ++s) {
        unsigned char c = (unsigned char)*s;
        char piece[6];
        long len;

        if (c == '"' || c == '\\') {
            piece[0] = '\\';
            piece[1] = (char)c;
            len = 2;
        } else if (c < 0x20 || c == 0x7F) {
            piece[0] = '\\';
            piece[1] = 'u';
            piece[2] = '0';
            piece[3] = '0';
            piece[4] = kHex[(c >> 4) & 0xF];
            piece[5] = kHex[c & 0xF];
            len = 6;
        } else if (c >= 0x80) {
            unsigned short code = k_macroman_high[c - 0x80];

            piece[0] = '\\';
            piece[1] = 'u';
            piece[2] = kHex[(code >> 12) & 0xF];
            piece[3] = kHex[(code >> 8) & 0xF];
            piece[4] = kHex[(code >> 4) & 0xF];
            piece[5] = kHex[code & 0xF];
            len = 6;
        } else {
            piece[0] = (char)c;
            len = 1;
        }

        if (len > cap - *pos) {
            return 0;
        }
        memcpy(buf + *pos, piece, (size_t)len);
        *pos += len;
    }
    return 1;
}

/* ---- the JSON renderer ---------------------------------------------------- */
/* Every reply shares one shape - CommandResult's own required fields (type,
 * id, ok), then either output.<key> or error{code,message} - so the
 * envelope bytes the contract requires verbatim are written in exactly one
 * place each.
 *
 * Everything variable goes through now68k_json_append_escaped, including
 * `key` and the row labels. Today those are always this build's own C
 * literals, where
 * escaping is a no-op; running them through it anyway means the renderer
 * has no "which of these fields is trusted" rule for a future command to
 * get wrong. */

static const char kOverflowNote[] = "(reply did not fit)";

static int build_json(const N68CmdResult *r, long id, const char *text,
                       char *out, long avail, long *pos)
{
    int ok = 1;

    *pos = 0;
    ok = ok && now68k_fmt_append_str(out, avail, pos,
                                      "{\"type\":\"command.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, pos, id);

    if (!r->ok) {
        ok = ok && now68k_fmt_append_str(out, avail, pos,
                                          ",\"ok\":false,\"error\":{\"code\":\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos, r->code);
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"message\":\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos, text);
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\"}}");
        return ok;
    }

    ok = ok && now68k_fmt_append_str(out, avail, pos,
                                      ",\"ok\":true,\"output\":{\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, r->key);
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\":[[\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, r->label);
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, text);
    if (r->state[0] != '\0') {
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\"],[\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos, r->label2);
        ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"");
        ok = ok && now68k_json_append_escaped(out, avail, pos, r->state);
    }
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\"]]}}");
    return ok;
}

long n68_cmdresult_render_json(const N68CmdResult *r, long id,
                                char *out, long cap)
{
    /* One byte of `cap` is reserved for the NUL terminator:
     * now68k_fmt_append_str/long and now68k_json_append_escaped will fill
     * a buffer right up to the capacity they are given, so building
     * against `cap`
     * itself and then writing out[pos] = '\0' could write one byte past the
     * caller's buffer. */
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;

    if (r == NULL) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }

    if (build_json(r, id, r->text, out, avail, &pos) && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    /* Compact fallback: same ok bit, same code, fixed text in place of the
     * message. kOverflowNote is this file's own literal, so it needs no
     * escaping, and - being short and constant - it always fits once the
     * envelope itself does. This is the one and only fallback, rather than
     * a chain of ever-shorter attempts. Shortening a reply must never
     * change what it claims happened. */
    if (build_json(r, id, kOverflowNote, out, avail, &pos) && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    if (cap > 0) {
        out[0] = '\0';
    }
    return 0;
}

/* ---- the console-text renderer -------------------------------------------- */

/* Appends `s` with control bytes dropped. A CR or LF inside a proc68.h
 * `detail` sentence would otherwise forge an extra console line - the ring
 * splits on exactly those bytes - so a one-line result would silently
 * become two, with the second one unattributed. High-bit MacRoman bytes go
 * through untouched: DrawText wants them raw. Returns 0 if it ran out of
 * room, having appended only whole bytes. */
static int append_text_safe(char *out, long avail, long *pos, const char *s)
{
    for (; *s != '\0'; ++s) {
        unsigned char c = (unsigned char)*s;

        if (c < 0x20 || c == 0x7F) {
            continue;
        }
        if (*pos >= avail) {
            return 0;
        }
        out[(*pos)++] = (char)c;
    }
    return 1;
}

long n68_cmdresult_render_text(const N68CmdResult *r, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;

    if (r == NULL || avail <= 0) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }

    if (!r->ok) {
        /* Marker and code first, message last: a line too narrow to hold
         * the whole sentence still says THAT it failed and which failure it
         * was. append_text_safe stops cleanly when it runs out, so a
         * truncated line is a short true line, never a mangled one. */
        (void)(append_text_safe(out, avail, &pos, "! ")
               && append_text_safe(out, avail, &pos, r->code)
               && append_text_safe(out, avail, &pos, ": ")
               && append_text_safe(out, avail, &pos, r->text));
    } else {
        (void)(append_text_safe(out, avail, &pos, r->label)
               && append_text_safe(out, avail, &pos, ": ")
               && append_text_safe(out, avail, &pos, r->text));
        if (r->state[0] != '\0') {
            /* CR, not LF: n68_linesplit accepts both, but the rest of this
             * guest writes CR (window.c's console_note) and a file that
             * mixes them invites a CRLF-is-one-break argument nobody needs
             * to have. */
            if (pos < avail) {
                out[pos++] = '\r';
            }
            (void)(append_text_safe(out, avail, &pos, r->label2)
                   && append_text_safe(out, avail, &pos, ": ")
                   && append_text_safe(out, avail, &pos, r->state));
        }
    }

    out[pos] = '\0';
    return pos;
}

/* ---- the table-shaped result ---------------------------------------------
 *
 * Everything below renders an N68CmdRows. It shares this file with the
 * one-row renderers deliberately: the two shapes have to agree on the
 * envelope bytes, the escaping and the "! code: message" failure line, and
 * the only arrangement that keeps them agreeing is one where a change to
 * either is visible while editing the other. */

void n68_cmdrows_init(N68CmdRows *r)
{
    if (r == NULL) {
        return;
    }
    memset(r, 0, sizeof *r);
}

int n68_cmdrows_add(N68CmdRows *r, const char *label, const char *value)
{
    N68CmdRow *row;

    if (r == NULL || r->count >= kN68CmdRowsMax) {
        return 0;
    }
    row = &r->rows[r->count];
    bounded_strcpy(row->label, (long)sizeof row->label, label);
    bounded_strcpy(row->value, (long)sizeof row->value, value);
    ++r->count;
    return 1;
}

void n68_cmdrows_set_error(N68CmdRows *r, const char *code,
                            const char *message)
{
    if (r == NULL) {
        return;
    }
    /* Rows already added are dropped rather than left behind the error.
     * A reply carrying both a table and a failure is one a reader has to
     * guess about, and the guess that reads the table is the wrong one. */
    n68_cmdrows_init(r);
    r->ok = 0;
    bounded_strcpy(r->code, (long)sizeof r->code, code);
    bounded_strcpy(r->text, (long)sizeof r->text, message);
}

/* One row's bytes, appended whole or not at all. `pos` is restored by the
 * caller on a 0 return - numfmt.h leaves it unspecified on failure, so it
 * cannot be trusted to have stopped anywhere in particular. */
static int append_row_json(const N68CmdRow *row, int first,
                            char *out, long avail, long *pos)
{
    int ok = 1;

    ok = ok && now68k_fmt_append_str(out, avail, pos, first ? "[\"" : ",[\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, row->label);
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\",\"");
    ok = ok && now68k_json_append_escaped(out, avail, pos, row->value);
    ok = ok && now68k_fmt_append_str(out, avail, pos, "\"]");
    return ok;
}

long n68_cmdrows_render_json(const N68CmdRows *r, long id,
                              char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;   /* one byte held for the NUL */
    long pos = 0;
    int ok = 1;
    int i;
    int emitted = 0;

    if (r == NULL) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }
    if (!r->ok) {
        /* A failure is one row's worth of information whatever shape the
         * success would have taken, so it is rendered by the renderer that
         * already exists rather than by a second copy of the error
         * envelope. The two shapes cannot disagree about a failure if only
         * one of them can express one. */
        N68CmdResult flat;

        n68_cmdresult_set_error(&flat, r->code, r->text);
        return n68_cmdresult_render_json(&flat, id, out, cap);
    }

    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      "{\"type\":\"command.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      ",\"ok\":true,\"output\":{\"");
    ok = ok && now68k_json_append_escaped(out, avail, &pos, r->key);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\":[");
    if (!ok) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }

    for (i = 0; i < r->count; ++i) {
        long saved = pos;
        /* Room for the tail always, and for the truncation note as well
         * whenever a row would be left over. Checked BEFORE committing to
         * this row, because a table that fills the buffer with rows and
         * then cannot say what it dropped is the silent-truncation failure
         * this whole shape exists to prevent. */
        long reserve = NOW68K_CMDROWS_TAIL_MAX
                       + ((i + 1 < r->count) ? NOW68K_CMDROWS_NOTE_MAX : 0);

        if (!append_row_json(&r->rows[i], emitted == 0, out, avail, &pos)
            || pos > avail - reserve) {
            pos = saved;
            break;
        }
        ++emitted;
    }

    if (emitted < r->count) {
        ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                          emitted == 0 ? "[\"...\",\""
                                                       : ",[\"...\",\"");
        ok = ok && now68k_fmt_append_long(out, avail, &pos,
                                           (long)(r->count - emitted));
        ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                          " more not shown\"]");
    }
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "]}}");
    if (!ok || pos <= 0) {
        /* Unreachable at NOW68K_CMDROWS_MIN_CAP - the reserve above is what
         * makes it so - but a caller blocked on a command.result must never
         * be left with a half-built buffer it might try to send. */
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

long n68_cmdrows_render_text(const N68CmdRows *r, char *out, long cap)
{
    /* The column the value starts in. Wide enough for most names on this
     * machine and narrow enough that a value still has room on a 58-column
     * pane; a longer label pushes its value right rather than being cut. */
    enum { kValueColumn = 20 };
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int i;

    if (r == NULL || avail <= 0) {
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }
    if (!r->ok) {
        N68CmdResult flat;

        n68_cmdresult_set_error(&flat, r->code, r->text);
        return n68_cmdresult_render_text(&flat, out, cap);
    }

    for (i = 0; i < r->count; ++i) {
        long rollback = pos;      /* includes this line's separator */
        long line_start;

        if (i > 0) {
            /* CR, not LF, for the reason the one-row renderer above gives:
             * n68_linesplit takes both and everything else this guest
             * writes is CR. */
            if (pos >= avail) {
                break;
            }
            out[pos++] = '\r';
        }
        line_start = pos;         /* column 0 of the line itself */
        if (!append_text_safe(out, avail, &pos, r->rows[i].label)) {
            pos = rollback;
            break;
        }
        while (pos - line_start < kValueColumn && pos < avail) {
            out[pos++] = ' ';
        }
        if (!append_text_safe(out, avail, &pos, r->rows[i].value)) {
            pos = rollback;
            break;
        }
    }

    out[pos] = '\0';
    return pos;
}
