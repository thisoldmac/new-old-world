/*
 * commands68.c - implementation of commands68.h: launch and quit.
 *
 * No malloc/NewPtr/NewHandle anywhere in this file - every buffer below is
 * a fixed, file-scope-sized local, matching the rest of guest68k/src.
 *
 * STATIC BUDGET (all stack, per call - this file owns no BSS):
 *   run_launch    name[200] + detail[160]                        = 360 B
 *   run_quit      QuitArgs(~40) + msg[80] + detail[160]           = 280 B
 * Neither runs while the other is on the stack (dispatch calls exactly
 * one), and both are well inside a 68K stack frame's normal headroom on a
 * machine with ~1.7 MB free. No recursion, no VLA.
 *
 * No printf family (numfmt.h's now68k_fmt_append_str/long only, matching
 * wire68.c) - snprintf drags newlib's float formatting into a 384 KB
 * partition for conversions this file never performs.
 */
#include "commands68.h"

#include "log.h"
#include "numfmt.h"
#include "proc68.h"

#include <string.h>

enum {
    kNameMax     = 200, /* launch: bare app name or a full HFS colon path */
    kQuitNameMax = 32,  /* proc68.h's ProcEntry.name[32] - the Str31 domain
                          * quit matches against; a longer argument cannot
                          * match any process. */
    kDetailCap   = 160, /* proc68.h: "a short ASCII sentence for the
                          * human" - both proc_launch_named and
                          * proc_quit_named are handed a buffer this size. */
    kFlagMax     = 16,  /* one leading "--wait"/"--no-wait" token */
    kMsgMax      = 80   /* a quit_parse() failure sentence, fixed text plus
                          * at most one echoed flag or number token */
};

enum {
    kQuitWaitDefaultSecs = 6,  /* mirrors proc_quit_args.h's
                                * kProcQuitWaitDefault (PPC guest,
                                * thread/guest-quit-command) */
    kQuitWaitMaxSecs     = 20, /* mirrors kProcQuitWaitMax, same file */
    kTicksPerSecond      = 60
};

/* ---- JSON string safety ------------------------------------------------- */

/* MacRoman 0x80..0xFF to Unicode, read the other way from the PowerPC
 * guest's own copy (now/guest/src/json.c, branch thread/guest-quit-
 * command, static k_macroman_high[]) - reproduced verbatim rather than
 * shared because that file lives in a different repo/build this client
 * cannot include. Used by append_json_escaped() below for bytes >= 0x80:
 * a process or HFS name on this platform routinely carries one of these
 * (an accented letter, a trademark sign), and it is ordinary text here,
 * not corruption. */
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

/* Appends `s` into buf[*pos, cap) as the BODY of a JSON string (the
 * caller writes the surrounding quotes) - real escaping, replacing the
 * previous sanitize_json_string() which mangled '"'/'\\'/control bytes to
 * '?' and let bytes >= 0x80 through raw. Both were real defects: '?'
 * corrupts a message that legitimately quoted a name ("nothing named
 * ?NetPresenz? is running"), and a raw high-bit byte inside a JSON string
 * is invalid UTF-8, which a spec-correct host parser rejects outright -
 * the whole frame is discarded and the caller's command blocks until the
 * 75 s idle timeout, not just that one field.
 *
 * The escaping mirrors the PowerPC guest's now_json_escape() (now/guest/
 * src/json.c, branch thread/guest-quit-command) rather than inventing a
 * weaker rule:
 *   - '"' and '\\'      -> backslash-escaped, so the literal cannot reopen
 *                          or corrupt.
 *   - < 0x20, or 0x7F    -> \u00XX. A raw control byte would corrupt the
 *                          control FRAME (text, newline-sensitive), not
 *                          just the JSON.
 *   - >= 0x80            -> \u escaped from its Unicode code point via
 *                          k_macroman_high, e.g. 0x87 (e-acute) becomes
 *                          \u00E9. DELIBERATE CHOICE: transliterating to
 *                          '?' (as the old sanitizer did for the low
 *                          range) would make an accented name and its
 *                          plain-ASCII near-miss collide, which is worse
 *                          for a caller matching launch/quit replies
 *                          against what it asked for than a few extra
 *                          bytes on the wire; escaping keeps the reply
 *                          both valid UTF-8-safe JSON and lossless.
 *
 * Bounded exactly like now68k_fmt_append_str: stops and returns 0 the
 * moment the next escaped piece would not fit, so no half-escaped
 * sequence is ever left in `buf`; no NUL is written here, matching
 * numfmt.h's append contract (the caller terminates once the whole chain
 * succeeds). No snprintf - hex digits are built by hand (standing rule:
 * no printf family in this file). */
static int append_json_escaped(char *buf, long cap, long *pos, const char *s)
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

static void bounded_strcpy(char *dst, long dst_cap, const char *src)
{
    long i = 0;

    if (dst_cap <= 0) {
        return;
    }
    while (i < dst_cap - 1 && src[i] != '\0') {
        dst[i] = src[i];
        ++i;
    }
    dst[i] = '\0';
}

static void bounded_copy_n(char *dst, long dst_cap, const char *src, long n)
{
    long i;

    if (dst_cap <= 0) {
        return;
    }
    if (n > dst_cap - 1) {
        n = dst_cap - 1;
    }
    if (n < 0) {
        n = 0;
    }
    for (i = 0; i < n; ++i) {
        dst[i] = src[i];
    }
    dst[i] = '\0';
}

/* ---- command.result envelope -------------------------------------------- */
/* Every reply this module builds shares this shape - CommandResult's own
 * required fields (type, id, ok), then either output.<name> or
 * error{code,message} - so the envelope bytes the contract requires
 * verbatim are written in exactly one place each. */

static int append_envelope(char *out, long cap, long *pos, long id)
{
    int ok = 1;

    ok = ok && now68k_fmt_append_str(out, cap, pos,
                                      "{\"type\":\"command.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, cap, pos, id);
    return ok;
}

/* A fixed fallback used only when the full reply would not fit `out`
 * within `cap`. It never echoes anything peer- or proc68.h-sourced, so it
 * carries no sanitize burden and - being short and constant - always fits
 * once the envelope itself does; this is the one and only fallback this
 * module reaches for, rather than a chain of ever-shorter attempts. */
static const char kOverflowNote[] = "(reply did not fit)";

/* Builds {"type":"command.result","id":id,"ok":false,"error":{"code":
 * code,"message":message}}, NUL-terminates it, and returns the number of
 * content bytes written (excluding the terminator) - `pos` is the only
 * truth here (compare wire68.c's own send path, which sends
 * (payload, pos), not strlen(payload)). Returns 0, with out[0] left as
 * '\0' (guarded on cap > 0 - a 0-byte `out` cannot even hold that), if
 * even the compact fallback did not fit `cap`; the caller must treat that
 * as nothing-to-send.
 *
 * `message` is escaped by append_json_escaped, not mutated - callers may
 * pass proc68.h's `detail` buffer or a locally-built sentence as-is.
 * `code` is always a fixed C string literal from this file, never peer
 * data, so it is appended verbatim, unescaped and unchecked.
 *
 * One byte of `cap` is reserved for the NUL terminator (`avail` below):
 * now68k_fmt_append_str/long and append_json_escaped are willing to fill
 * a buffer right up to the capacity they are given, so building against
 * `cap` itself and then writing out[pos] = '\0' could write one byte past
 * the caller's buffer. */
static long finish_error(char *out, long cap, long id, const char *code,
                          const char *message)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;

    ok = ok && append_envelope(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      ",\"ok\":false,\"error\":{\"code\":\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, code);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"message\":\"");
    ok = ok && append_json_escaped(out, avail, &pos, message);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"}}");
    if (ok && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    /* Compact fallback: same code (still a true statement), fixed text
     * instead of `message` - kOverflowNote is this file's own literal, so
     * it needs no escaping. ok stays false either way - shortening a
     * reply must never change what it claims happened. */
    pos = 0;
    ok = 1;
    ok = ok && append_envelope(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      ",\"ok\":false,\"error\":{\"code\":\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, code);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"message\":\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, kOverflowNote);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"}}");
    if (ok && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    now68k_log("cmd: error reply did not fit even the compact fallback");
    if (cap > 0) {
        out[0] = '\0';
    }
    return 0;
}

/* Builds a one-row ok:true reply: output.<key> = [[label,value]]. Used by
 * launch. NUL-terminates and returns the byte count, same contract as
 * finish_error above. `value` is escaped by append_json_escaped, not
 * mutated. */
static long finish_ok_row1(char *out, long cap, long id, const char *key,
                            const char *label, const char *value)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;

    ok = ok && append_envelope(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"ok\":true,\"output\":{\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, key);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\":[[\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, label);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
    ok = ok && append_json_escaped(out, avail, &pos, value);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"]]}}");
    if (ok && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    pos = 0;
    ok = 1;
    ok = ok && append_envelope(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"ok\":true,\"output\":{\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, key);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\":[[\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, label);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, kOverflowNote);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"]]}}");
    if (ok && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    now68k_log("cmd: ok reply did not fit even the compact fallback");
    if (cap > 0) {
        out[0] = '\0';
    }
    return 0;
}

/* Builds the two-row ok:true reply quit uses: output.quit =
 * [["Quit",value1],["Outcome",value2]]. NUL-terminates and returns the
 * byte count, same contract as finish_error above. value2 (the outcome
 * state word) is a fixed literal from this file's own table and needs no
 * escaping; value1 (proc68.h's `detail`) is escaped by
 * append_json_escaped, not mutated. */
static long finish_ok_row2(char *out, long cap, long id, const char *key,
                            const char *label1, const char *value1,
                            const char *label2, const char *value2)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;

    ok = ok && append_envelope(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"ok\":true,\"output\":{\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, key);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\":[[\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, label1);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
    ok = ok && append_json_escaped(out, avail, &pos, value1);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"],[\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, label2);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, value2);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"]]}}");
    if (ok && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    pos = 0;
    ok = 1;
    ok = ok && append_envelope(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",\"ok\":true,\"output\":{\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, key);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\":[[\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, label1);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, kOverflowNote);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"],[\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, label2);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, value2);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"]]}}");
    if (ok && pos > 0) {
        out[pos] = '\0';
        return pos;
    }

    now68k_log("cmd: ok reply did not fit even the compact fallback");
    if (cap > 0) {
        out[0] = '\0';
    }
    return 0;
}

/* ---- launch --------------------------------------------------------------- */

/* Trims leading/trailing spaces and, if the whole remainder is wrapped in
 * one matching pair, one layer of double quotes - the same courtesy
 * proc_quit_args.c extends a quoted process name (quotes are never
 * required, but a person who types them means the text inside them).
 *
 * Returns 1 and fills `out` on success. Returns 0, leaving `out`
 * untouched, if the trimmed/unquoted text does not fit `out_cap` - it
 * used to truncate silently instead (bounded_copy_n's normal behavior),
 * which meant a full HFS path longer than kNameMax got launched, or
 * reported not-found, UNDER THE TRUNCATED NAME: the error named
 * something the caller never asked for. A full path on a nested volume
 * routinely exceeds 200 bytes, so refusing outright - not shortening -
 * is the only honest option here. */
static int trim_and_unquote(const char *in, char *out, long out_cap)
{
    long len = (long)strlen(in);
    long start = 0;
    long n;

    while (start < len && in[start] == ' ') {
        ++start;
    }
    while (len > start && in[len - 1] == ' ') {
        --len;
    }
    if (len - start >= 2 && in[start] == '"' && in[len - 1] == '"') {
        ++start;
        --len;
    }
    n = len - start;
    if (n >= out_cap) {
        return 0;
    }
    bounded_copy_n(out, out_cap, in + start, n);
    return 1;
}

static long run_launch(const char *target, long id, char *out, long cap)
{
    char name[kNameMax];
    char detail[kDetailCap];
    short err;

    if (!trim_and_unquote(target != NULL ? target : "", name, sizeof name)) {
        bounded_strcpy(detail, sizeof detail,
                       "launch: target name is too long (199 chars max) "
                       "- refused, not truncated");
        return finish_error(out, cap, id, "launch-bad-args", detail);
    }

    if (name[0] == '\0') {
        bounded_strcpy(detail, sizeof detail,
                       "launch: what? (an application name or a colon "
                       "path)");
        return finish_error(out, cap, id, "launch-bad-args", detail);
    }
    /* proc_launch_named (proc68.h) resolves a bare name by exact-name
     * catalog search, or a colon-containing string as a full HFS path
     * used directly - full stop. It has no notion of the contract's
     * optional "-v VERSION" disambiguator or "#n" stored-match selector
     * (x-commands.launch, contract/asyncapi.yaml) - there is no stored
     * match list on this client at all. Refusing a leading "-v" or a
     * "#n" selector here, rather than handing it to proc_launch_named as
     * a literal filename, is the honest version of that gap: a real
     * application named "-v 1.1.1 SimpleText" is not what a caller who
     * typed the contract's disambiguator syntax meant, and proc68.h's
     * plain fnfErr for "no such file" would not say so. See the
     * deliverable report for this divergence. */
    if (name[0] == '-'
        || (name[0] == '#' && name[1] >= '0' && name[1] <= '9')) {
        bounded_strcpy(detail, sizeof detail,
                       "launch: -v and #n are not implemented on this "
                       "client (name or a colon path only)");
        return finish_error(out, cap, id, "launch-bad-args", detail);
    }

    err = proc_launch_named(name, detail, sizeof detail);
    if (err != 0) {
        now68k_log_num("cmd: launch refused", (long)err);
        return finish_error(out, cap, id, "launch-refused", detail);
    }
    now68k_log("cmd: launch ok");
    return finish_ok_row1(out, cap, id, "launch", "Launch", detail);
}

/* ---- quit ------------------------------------------------------------------ */
/* Mirrors proc_quit_args.c's grammar exactly (now/guest/src/
 * proc_quit_args.c, branch thread/guest-quit-command): flags are LEADING
 * because the name is the whole rest of the line and process names
 * contain spaces ("Apple File Security"). Reproduced rather than shared
 * because that file lives in a different repo/build (the PPC guest and
 * its host-side unit test) with no header this client can include - this
 * is the same grammar in a second place, not a second one invented
 * against it.
 *
 * This client exposes fewer flags than that file's ProcQuitArgs: no
 * --all, because proc68.h's proc_quit_named takes no such parameter -
 * it is not this file's decision to make what happens with several
 * matching processes, and proc68.h's own outcome vocabulary already
 * covers that case (kProcAmbiguous, "refused rather than guess one" per
 * proc68.h's ProcOutcome doc). See the deliverable report. */

typedef struct {
    char name[kQuitNameMax];
    long wait_ticks; /* 0 after --no-wait: send, do not confirm */
} QuitArgs;

/* Copies one whitespace-delimited token, returning where it stopped. Same
 * shape as proc_quit_args.c's static token(). */
static const char *quit_token(const char *p, char *out, long cap)
{
    long n = 0;

    while (*p == ' ') {
        ++p;
    }
    while (*p != '\0' && *p != ' ' && n + 1 < cap) {
        out[n++] = *p++;
    }
    out[n] = '\0';
    return p;
}

/* Hand-rolled equivalent of strtol(s, NULL, 10) for a small non-negative
 * count: parses leading digits (an optional leading '-' is recognized so
 * a negative count is rejected below rather than misread as positive),
 * stops at the first non-digit rather than requiring one. Same tolerance
 * proc_quit_args.c gets from strtol itself ("--wait 12x" parses as 12) -
 * intentionally not stricter, to keep the grammar identical rather than
 * merely similar. */
static long parse_secs(const char *s)
{
    long v = 0;
    int neg = 0;

    if (*s == '-') {
        neg = 1;
        ++s;
    }
    while (*s >= '0' && *s <= '9') {
        v = v * 10 + (*s - '0');
        ++s;
    }
    return neg ? -v : v;
}

static int quit_parse(const char *arg, QuitArgs *out, char *msg, long cap)
{
    const char *p = arg != NULL ? arg : "";
    long len;

    memset(out, 0, sizeof *out);
    out->wait_ticks = (long)kQuitWaitDefaultSecs * kTicksPerSecond;

    for (;;) {
        char flag[kFlagMax];
        const char *after;

        while (*p == ' ') {
            ++p;
        }
        if (*p != '-') {
            break;
        }
        after = quit_token(p, flag, sizeof flag);
        if (strcmp(flag, "--no-wait") == 0) {
            out->wait_ticks = 0;
        } else if (strcmp(flag, "--wait") == 0) {
            char number[kFlagMax];
            long secs;

            after = quit_token(after, number, sizeof number);
            secs = parse_secs(number);
            if (number[0] == '\0' || secs < 1) {
                bounded_strcpy(msg, cap,
                               "quit: --wait needs a number of seconds "
                               "(1-20)");
                return 0;
            }
            if (secs > kQuitWaitMaxSecs) {
                secs = kQuitWaitMaxSecs; /* clamp, do not refuse: the
                                          * ceiling is ours, not theirs */
            }
            out->wait_ticks = secs * kTicksPerSecond;
        } else {
            char line[kMsgMax];
            long pos = 0;

            now68k_fmt_append_str(line, (long)sizeof line, &pos,
                                   "quit: no flag \"");
            now68k_fmt_append_str(line, (long)sizeof line, &pos, flag);
            now68k_fmt_append_str(line, (long)sizeof line, &pos, "\"");
            if (pos < 0 || pos >= (long)sizeof line) {
                pos = (long)sizeof(line) - 1;
            }
            line[pos] = '\0';
            bounded_strcpy(msg, cap, line);
            return 0;
        }
        p = after;
    }

    while (*p == ' ') {
        ++p;
    }
    len = (long)strlen(p);
    while (len > 0 && p[len - 1] == ' ') {
        --len; /* a trailing space is typing, not part of the name */
    }
    if (len >= 2 && p[0] == '"' && p[len - 1] == '"') {
        ++p;
        len -= 2;
    }
    if (len == 0) {
        bounded_strcpy(msg, cap,
                       "quit: what? (the name of a running process)");
        return 0;
    }
    if (len >= kQuitNameMax) {
        bounded_strcpy(msg, cap,
                       "quit: no process name is longer than 31 "
                       "characters");
        return 0;
    }
    bounded_copy_n(out->name, (long)sizeof out->name, p, len);
    return 1;
}

static long run_quit(const char *target, long id, char *out, long cap)
{
    QuitArgs args;
    char msg[kMsgMax];
    char detail[kDetailCap];
    ProcOutcome outcome;
    const char *state;
    const char *code;

    if (!quit_parse(target != NULL ? target : "", &args, msg, sizeof msg)) {
        return finish_error(out, cap, id, "quit-bad-args", msg);
    }

    outcome = proc_quit_named(args.name, args.wait_ticks, detail,
                               sizeof detail);

    /* proc68.h's ProcOutcome, mapped to the wire exactly the way its own
     * doc comment requires: kProcGone and kProcNotRunning are ok:true -
     * the asked-for state (not running) holds either way. kProcSent-
     * Unconfirmed is also ok:true, and deliberately so, mirroring the PPC
     * guest's run_quit (now/guest/src/commands.c, branch
     * thread/guest-quit-command): it means the caller itself asked not to
     * wait (--no-wait), so "we cannot confirm" is not a failure of this
     * command, it is the command doing exactly what was asked - an ok:
     * false here would make --no-wait useless for the probe loop it
     * exists for, spuriously failing every call that used it on purpose.
     * Everything past that is ok:false with a code naming why: none of
     * kProcStillRunning/kProcAmbiguous/kProcRefusedSelf/
     * kProcUndeliverable/kProcBadArgs let a caller trust the process is
     * actually gone, and that is the one thing this reply's ok bit
     * promises. Each case gets its own break (no fallthrough) so nothing
     * here depends on enum ordering. */
    switch (outcome) {
    case kProcGone:
        state = "gone";
        code = NULL;
        break;
    case kProcNotRunning:
        state = "not-running";
        code = NULL;
        break;
    case kProcSentUnconfirmed:
        state = "sent-unconfirmed";
        code = NULL;
        break;
    case kProcStillRunning:
        state = "still-running";
        code = "quit-declined";
        break;
    case kProcAmbiguous:
        state = "ambiguous";
        code = "quit-ambiguous";
        break;
    case kProcRefusedSelf:
        state = "refused-self";
        code = "quit-refused";
        break;
    case kProcUndeliverable:
        state = "undeliverable";
        code = "quit-undeliverable";
        break;
    case kProcBadArgs:
        state = "bad-args";
        code = "quit-bad-args";
        break;
    default:
        state = "bad-args";
        code = "quit-bad-args";
        break;
    }

    now68k_log_num(code == NULL ? "cmd: quit ok" : "cmd: quit not-gone",
                    (long)outcome);

    if (code != NULL) {
        return finish_error(out, cap, id, code, detail);
    }
    return finish_ok_row2(out, cap, id, "quit", "Quit", detail, "Outcome",
                           state);
}

/* ---- help ------------------------------------------------------------------- */

/* What THIS Mac serves - three commands, and it says three.
 *
 * The other side keeps no command list: there are two guests with different
 * tables (the PowerPC Carbon guest implements fifteen commands, this one
 * implements two plus this), so a console-side list would be wrong for both.
 * Discovery is therefore a request like any other, and the honest answer
 * from here is a short one. The PowerPC guest answers the same command from
 * its own table (guest/src/cmd_help.c); this table is deliberately separate
 * rather than shared, because the two applications share no source - they
 * meet only on the wire, and the contract is the thing they hold in common.
 *
 * The trailing note row is not decoration. A human reading three commands
 * needs to know whether that is all this machine HAS or all it would admit
 * to; saying "everything else answers unknown-command" is the difference
 * between a short list and a suspicious one. */
typedef struct {
    const char *name;
    const char *summary;
    const char *usage;
} N68CommandDoc;

static const N68CommandDoc k_docs[] = {
    { "launch", "open an application on this Mac",
      "launch <name | full path>" },
    { "quit", "ask an application on this Mac to quit",
      "quit [--all] [--wait N | --no-wait] <name>" },
    { "help", "list the commands this Mac serves",
      "help [command]" },
    { NULL, NULL, NULL }
};

static const char kHelpNote[] =
    "every other command answers unknown-command";

/* Appends ["label","value"], with the separating comma when something is
 * already in the array. Returns 0 if it did not fit, leaving `pos` where it
 * was so the caller can close the array on what did. */
static int append_row(char *out, long cap, long *pos, int first,
                      const char *label, const char *value)
{
    long saved = *pos;
    int ok = 1;

    if (!first) {
        ok = ok && now68k_fmt_append_str(out, cap, pos, ",");
    }
    ok = ok && now68k_fmt_append_str(out, cap, pos, "[\"");
    ok = ok && append_json_escaped(out, cap, pos, label);
    ok = ok && now68k_fmt_append_str(out, cap, pos, "\",\"");
    ok = ok && append_json_escaped(out, cap, pos, value);
    ok = ok && now68k_fmt_append_str(out, cap, pos, "\"]");
    if (!ok) {
        *pos = saved;
        return 0;
    }
    return 1;
}

static long run_help(const char *target, long id, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int first = 1;
    int ok = 1;
    int i;
    char topic[32];

    topic[0] = '\0';
    if (target != NULL && !trim_and_unquote(target, topic, (long)sizeof topic)) {
        /* Too long to be any command's name, so it is not one. */
        return finish_error(out, cap, id, "unknown-command",
                            "that is not a command this Mac knows");
    }

    if (topic[0] != '\0') {
        for (i = 0; k_docs[i].name != NULL; ++i) {
            if (strcmp(k_docs[i].name, topic) == 0) {
                return finish_ok_row2(out, cap, id, "help",
                                       k_docs[i].name, k_docs[i].summary,
                                       "Usage", k_docs[i].usage);
            }
        }
        return finish_error(out, cap, id, "unknown-command",
                            "that is not a command this Mac knows");
    }

    ok = ok && append_envelope(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      ",\"ok\":true,\"output\":{\"help\":[");
    if (!ok) {
        now68k_log("cmd: help reply did not fit its envelope");
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }
    for (i = 0; k_docs[i].name != NULL; ++i) {
        if (!append_row(out, avail, &pos, first, k_docs[i].name,
                        k_docs[i].summary)) {
            break;
        }
        first = 0;
    }
    /* The note is dropped before any command row is: a truncated list with
     * the note still attached would claim completeness it does not have. */
    (void)append_row(out, avail, &pos, first, "", kHelpNote);
    ok = now68k_fmt_append_str(out, avail, &pos, "]}}");
    if (!ok || pos <= 0) {
        now68k_log("cmd: help reply did not fit");
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

/* ---- dispatch --------------------------------------------------------------- */

int now68k_commands_dispatch(const char *name, const char *target, long id,
                              char *out, long cap, long *out_len)
{
    long len;

    if (name == NULL) {
        return 0;
    }
    if (strcmp(name, "help") == 0) {
        len = run_help(target, id, out, cap);
        if (out_len != NULL) {
            *out_len = len;
        }
        return 1;
    }
    if (strcmp(name, "launch") == 0) {
        len = run_launch(target, id, out, cap);
        if (out_len != NULL) {
            *out_len = len;
        }
        return 1;
    }
    if (strcmp(name, "quit") == 0) {
        len = run_quit(target, id, out, cap);
        if (out_len != NULL) {
            *out_len = len;
        }
        return 1;
    }
    return 0;
}
