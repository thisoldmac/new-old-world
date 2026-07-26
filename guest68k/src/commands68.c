/*
 * commands68.c - implementation of commands68.h: launch and quit.
 *
 * No malloc/NewPtr/NewHandle anywhere in this file - every buffer below is
 * a fixed, file-scope-sized local, matching the rest of guest68k/src.
 *
 * STATIC BUDGET (stack per call, plus one BSS block):
 *   run_launch    name[200] + detail[160]                        = 360 B
 *   run_quit      QuitArgs(~40) + msg[80] + detail[160]           = 280 B
 *   run_vprobe    why[160]                                       = 160 B
 *   dispatch      one N68CmdResult                               = 256 B
 *   g_vprobe      one N68VProbeTable, BSS                        = ~820 B
 * No two run_* are on the stack at once (dispatch calls exactly one), so
 * the deepest frame is dispatch's 256 plus run_launch's 360 = ~616 B -
 * well inside a 68K stack frame's normal headroom on a machine with
 * ~1.7 MB free. No recursion, no VLA.
 *
 * The one BSS block is the vprobe row table, and it is BSS rather than a
 * local precisely because this file's callers can be several levels deep
 * by the time a command runs (wire68.c -> dispatch, and a pumped nested
 * dispatch on top of that - proc68.c measured ~3.7 KB per level). See its
 * comment for why one instance is also the right number.
 *
 * No printf family (numfmt.h's now68k_fmt_append_str/long only, matching
 * wire68.c) - snprintf drags newlib's float formatting into a 384 KB
 * partition for conversions this file never performs.
 */
#include "commands68.h"

#include "log.h"
#include "n68_cmdresult.h"
#include "n68_proclist.h"
#include "n68_vprobe.h"
#include "numfmt.h"
#include "proc68.h"
#include "vprobe68.h"
/* The one command whose whole meaning is "put this on the wire", so this
 * layer reaches down to the transport for it. wire68.c already reaches up
 * to this file for dispatch; the cycle is between translation units, not
 * headers, and the alternative - a second dispatch inside wire68.c - is
 * the two-implementations shape docs/command-parity.md exists to stop. */
#include "wire68.h"

#include <string.h>

enum {
    kNameMax     = 200, /* launch: bare app name or a full HFS colon path */
    kQuitNameMax = 32,  /* proc68.h's ProcEntry.name[32] - the Str31 domain
                          * quit matches against; a longer argument cannot
                          * match any process. */
    kDetailCap   = kN68CmdTextCap,
                        /* proc68.h: "a short ASCII sentence for the
                          * human" - both proc_launch_named and
                          * proc_quit_named are handed a buffer this size.
                          * It is n68_cmdresult.h's number now, not a
                          * second 160 that could drift from the one the
                          * renderers size their text field to. */
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

/* ---- everything that BUILT a reply has MOVED ------------------------------ */
/* The MacRoman escape table, append_json_escaped(), append_envelope and the
 * three finish_* builders (finish_error, finish_ok_row1, finish_ok_row2 -
 * now one function with a row count) are all n68_cmdresult.c.
 *
 * They left because this file gained a SECOND reader: the interactive
 * console window renders the same commands as text for a human (conwin.h),
 * and a command that runs and formats in one pass can only serve a second
 * reader by being implemented twice. See n68_cmdresult.h - the whole point
 * of that file is that the second implementation does not get written. What
 * is left below is what a command DOES; what a result LOOKS LIKE now lives
 * in exactly one other place, with both renderings side by side so they
 * cannot drift.
 *
 * The wire did not change, and that is checked rather than asserted: the
 * old builders and the new renderer were run side by side over 1,092
 * combinations of reply shape, message, error code and output capacity and
 * agreed on every byte and every returned length (see docs/open-issues.md,
 * and n68_cmdresult.h for the one input class - a message over 159 bytes -
 * where they would not, which no caller here can produce).
 * now68k_commands_dispatch below still has the signature and return-value
 * contract commands68.h documents. */
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

static void run_launch(const char *target, N68CmdResult *res)
{
    char name[kNameMax];
    char detail[kDetailCap];
    short err;

    if (!trim_and_unquote(target != NULL ? target : "", name, sizeof name)) {
        bounded_strcpy(detail, sizeof detail,
                       "launch: target name is too long (199 chars max) "
                       "- refused, not truncated");
        n68_cmdresult_set_error(res, "launch-bad-args", detail);
        return;
    }

    if (name[0] == '\0') {
        bounded_strcpy(detail, sizeof detail,
                       "launch: what? (an application name or a colon "
                       "path)");
        n68_cmdresult_set_error(res, "launch-bad-args", detail);
        return;
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
        n68_cmdresult_set_error(res, "launch-bad-args", detail);
        return;
    }

    err = proc_launch_named(name, detail, sizeof detail);
    if (err != 0) {
        now68k_log_num("cmd: launch refused", (long)err);
        n68_cmdresult_set_error(res, "launch-refused", detail);
        return;
    }
    now68k_log("cmd: launch ok");
    n68_cmdresult_set_ok1(res, "launch", "Launch", detail);
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

static void run_quit(const char *target, N68CmdResult *res)
{
    QuitArgs args;
    char msg[kMsgMax];
    char detail[kDetailCap];
    ProcOutcome outcome;
    const char *state;
    const char *code;

    if (!quit_parse(target != NULL ? target : "", &args, msg, sizeof msg)) {
        n68_cmdresult_set_error(res, "quit-bad-args", msg);
        return;
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
        n68_cmdresult_set_error(res, code, detail);
        return;
    }
    n68_cmdresult_set_ok2(res, "quit", "Quit", detail, "Outcome", state);
}

/* ---- vprobe ----------------------------------------------------------------- */

/* THE TABLE LIVES HERE, IN BSS, AND THERE IS EXACTLY ONE.
 *
 * 17 rows x 48 bytes + 4 = ~820 bytes, which is too much to put on a stack
 * frame that wire68.c's command path can already re-enter (proc68.c
 * measured ~3.7 KB per nested level before its `pumping` guard). One
 * instance rather than one per face is also what makes the two faces
 * render the SAME measurement: run_vprobe() fills it, the wire renders it
 * as a row array and the console renders the two-row summary of it. It is
 * never read after the call that filled it returns, so nothing depends on
 * it surviving - it is here for the stack, not for the lifetime.
 *
 * vprobe68_run refuses re-entry (kVProbe68Busy), so two probes can never
 * be writing this table at once. */
static N68VProbeTable g_vprobe;

const N68VProbeTable *now68k_commands_vprobe(char *why, long why_cap)
{
    if (why != NULL && why_cap > 0) {
        why[0] = '\0';
    }
    if (vprobe68_run(&g_vprobe, why, why_cap) != kVProbe68OK) {
        return NULL;
    }
    return &g_vprobe;
}

static VProbe68Status run_vprobe(N68CmdResult *res)
{
    char why[kDetailCap];
    VProbe68Status status;

    why[0] = '\0';
    status = vprobe68_run(&g_vprobe, why, (long)sizeof why);
    if (status != kVProbe68OK) {
        now68k_log_num("cmd: vprobe refused", (long)status);
        /* One code for "did not run", the sentence for which of the ways.
         * A caller that asked for a measurement and got none needs to know
         * whether the machine refused (no screen, geometry that did not
         * check out) or was busy - and both are ok:false, because an empty
         * table dressed as a success is the one answer a measurement
         * command must never give. */
        n68_cmdresult_set_error(res, status == kVProbe68Busy
                                         ? "vprobe-busy" : "vprobe-refused",
                                why[0] != '\0' ? why
                                               : "vprobe could not measure "
                                                 "this Mac");
        return status;
    }
    now68k_log_num("cmd: vprobe ok", (long)g_vprobe.count);
    return kVProbe68OK;
}

/* ---- help ------------------------------------------------------------------- */

/* What THIS Mac serves - four commands, and it says four.
 *
 * The other side keeps no command list: there are two guests with different
 * tables (the PowerPC Carbon guest implements fifteen commands, this one
 * implements two through now68k_commands_run plus help, ps and vprobe,
 * which each build a row per item and so answer at dispatch), so a
 * console-side list would be wrong for both. Discovery is therefore a
 * request like any other, and the honest answer from here is a short one.
 * It is also the ONLY thing the host console's Tab completion has to go on,
 * which is the second reason a command missing from this table is a command
 * a person cannot find. The PowerPC guest answers the same command from its
 * own table (guest/src/cmd_help.c); this table is deliberately separate
 * rather than shared, because the two applications share no source - they
 * meet only on the wire, and the contract is the thing they hold in common.
 *
 * The trailing note row is not decoration. A human reading four commands
 * needs to know whether that is all this machine HAS or all it would admit
 * to; saying "everything else answers unknown-command" is the difference
 * between a short list and a suspicious one. */
static const N68CommandDoc k_docs[] = {
    { "launch", "open an application on this Mac",
      "launch <name | full path>" },
    { "quit", "ask an application on this Mac to quit",
      "quit [--all] [--wait N | --no-wait] <name>" },
    { "help", "list the commands this Mac serves",
      "help [command]" },
    { "ps", "the processes running on this Mac", "ps" },
    { "vprobe", "measure this Mac's VRAM read cost",
      "vprobe (no arguments; wants a still screen)" },
    { "put", "send a file from this Mac to the host", "put <file name>" },
    { NULL, NULL, NULL }
};

const N68CommandDoc *now68k_commands_docs(void)
{
    return k_docs;
}

static const char kHelpNote[] =
    "every other command answers unknown-command";


static long run_help(const char *target, long id, char *out, long cap)
{
    long avail = cap > 0 ? cap - 1 : 0;
    long pos = 0;
    int ok = 1;
    int i;
    char topic[32];

    topic[0] = '\0';
    if (target != NULL
        && !trim_and_unquote(target, topic, (int)sizeof topic)) {
        topic[0] = '\0';   /* too long to be any command's name */
    }

    /* One command asked about by name: a single row pair, which is exactly
     * what an N68CmdResult holds - so it goes through the same renderer
     * every other reply uses rather than building JSON by hand. */
    if (topic[0] != '\0') {
        N68CmdResult res;

        n68_cmdresult_init(&res);
        for (i = 0; k_docs[i].name != NULL; ++i) {
            if (strcmp(k_docs[i].name, topic) == 0) {
                res.ok = 1;
                bounded_strcpy(res.key, sizeof res.key, "help");
                bounded_strcpy(res.label, sizeof res.label,
                               k_docs[i].name);
                bounded_strcpy(res.text, sizeof res.text,
                               k_docs[i].summary);
                bounded_strcpy(res.label2, sizeof res.label2, "Usage");
                bounded_strcpy(res.state, sizeof res.state,
                               k_docs[i].usage);
                return n68_cmdresult_render_json(&res, id, out, cap);
            }
        }
        res.ok = 0;
        bounded_strcpy(res.code, sizeof res.code, "unknown-command");
        bounded_strcpy(res.text, sizeof res.text,
                       "that is not a command this Mac knows");
        return n68_cmdresult_render_json(&res, id, out, cap);
    }

    /* The whole list: a row PER COMMAND, which no single N68CmdResult can
     * hold, so this one builder stays. Every string below is one of this
     * file's own literals (k_docs, kHelpNote), so nothing here needs JSON
     * escaping - the moment that stops being true, it does. */
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      "{\"type\":\"command.result\",\"id\":");
    ok = ok && now68k_fmt_append_long(out, avail, &pos, id);
    ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                      ",\"ok\":true,\"output\":{\"help\":[");
    for (i = 0; ok && k_docs[i].name != NULL; ++i) {
        if (i > 0) {
            ok = ok && now68k_fmt_append_str(out, avail, &pos, ",");
        }
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "[\"");
        ok = ok && now68k_fmt_append_str(out, avail, &pos, k_docs[i].name);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "\",\"");
        ok = ok && now68k_fmt_append_str(out, avail, &pos,
                                          k_docs[i].summary);
        ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"]");
    }
    ok = ok && now68k_fmt_append_str(out, avail, &pos, ",[\"note\",\"");
    ok = ok && now68k_fmt_append_str(out, avail, &pos, kHelpNote);
    ok = ok && now68k_fmt_append_str(out, avail, &pos, "\"]]}}");
    if (!ok || pos <= 0) {
        now68k_log("cmd: help reply did not fit its envelope");
        if (cap > 0) {
            out[0] = '\0';
        }
        return 0;
    }
    out[pos] = '\0';
    return pos;
}

/* ps: the running processes as flat [name, detail] rows.
 *
 * Like help, it answers below now68k_commands_run rather than through it,
 * and for the same structural reason: its reply is a ROW PER PROCESS and
 * an N68CmdResult holds one row. What keeps that safe is that it is not a
 * second process walk - proc_list_rows() is the one implementation, and
 * this file only asks n68_proclist.c to render the rows the way the
 * console renders them as text (conwin.c) and the wire renders them as
 * process.listing. Three faces, one walk (docs/command-parity.md).
 *
 * It exists on the wire because the host console is a DUMB SHELL: it
 * relays whatever a person types and knows no command list, so a
 * capability NOW-68K served only as a message family was unreachable from
 * the host's console even though the guest's own console had it. `ps`
 * typed there answered unknown-command while the same guest listed
 * processes happily at its own keyboard - watched 2026-07-25. */
/* The one caller in the shipping build hands over NOW68K_CONTROL_SEND_CAP,
 * which is larger, but this is the number this module PROMISES its callers
 * (commands68.h), so it is the one that has to hold a ps reply with a row
 * in it. The 160-vs-512 command.result bug was exactly a build where two
 * limits disagreed and only the smaller one was ever checked. */
_Static_assert(NOW68K_COMMAND_RESULT_CAP >= NOW68K_PS_MIN_CAP,
               "a ps reply must fit a command.result buffer with at least "
               "one process in it and still be able to say what it dropped");

static long run_ps(long id, char *out, long cap)
{
    N68ProcRow rows[NOW68K_PROCLIST_MAX_ROWS];
    long count = proc_list_rows(rows, (long)NOW68K_PROCLIST_MAX_ROWS);

    if (count < 0) {
        count = 0;   /* the Process Manager gave nothing: an empty list is
                      * the truthful answer, not an error */
    }
    return n68_proclist_render_ps(id, rows, count, out, cap);
}

/* `put` is a COMMAND on this guest and only a console verb on the
 * PowerPC one, and the difference is deliberate.
 *
 * There, the host reaches the same capability through the file.* message
 * families, so a person at the guest gets a console verb and the wire
 * needs none. Here, the host's console is a dumb shell that relays a
 * typed line as a command.request and knows no families - and on a
 * PowerBook 180c whose display is often the only face anyone has, the
 * console cannot be the only place a file can be sent from either. So it
 * belongs in this table, where BOTH faces reach one implementation, which
 * is the lesson `ps` cost a day to learn (docs/command-parity.md).
 *
 * One row, so it goes through now68k_commands_run and the console gets
 * it for free rather than through a second dispatch in conwin.c. What the
 * row says is that the OFFER went out, not that the file arrived: the
 * transfer runs from wire_idle() afterwards and its outcome is what
 * `xfer` reports. Blocking here until a multi-megabyte file lands would
 * hold the reply the host is waiting on for minutes. */
static void run_put(const char *target, N68CmdResult *res)
{
    char leaf[64];
    char why[96];

    if (target == NULL
        || !trim_and_unquote(target, leaf, (int)sizeof leaf)
        || leaf[0] == '\0') {
        n68_cmdresult_set_error(res, "bad-request",
                                "put needs the name of a file in this "
                                "application's folder");
        return;
    }
    if (!now68k_wire_send_file(leaf, why, (long)sizeof why)) {
        n68_cmdresult_set_error(res, "put-refused", why);
        return;
    }
    res->ok = 1;
    bounded_strcpy(res->key, sizeof res->key, "put");
    bounded_strcpy(res->label, sizeof res->label, leaf);
    bounded_strcpy(res->text, sizeof res->text, "offered to the host");
}

/* ---- dispatch --------------------------------------------------------------- */

int now68k_commands_run(const char *name, const char *target,
                         N68CmdResult *res)
{
    if (name == NULL || res == NULL) {
        return 0;
    }
    n68_cmdresult_init(res);

    if (strcmp(name, "launch") == 0) {
        run_launch(target, res);
        return 1;
    }
    if (strcmp(name, "quit") == 0) {
        run_quit(target, res);
        return 1;
    }
    /* vprobe reaches the CONSOLE through here - that is the whole point of
     * this seam (docs/command-parity.md): a verb in this function is a verb
     * conwin.c can run without knowing it exists. What the console gets is
     * the two-row summary, because an N68CmdResult holds two rows and the
     * probe produces sixteen; the wire gets all sixteen through
     * now68k_commands_dispatch below. Both render ONE table filled by one
     * implementation, which is the property that matters - but the console
     * seeing less of it than the host is a real asymmetry, written down at
     * n68_vprobe_render_text (the renderer that closes it) rather than left
     * to be discovered. */
    if (strcmp(name, "vprobe") == 0) {
        if (run_vprobe(res) == kVProbe68OK) {
            n68_vprobe_summary(&g_vprobe, res);
        }
        return 1;
    }
    if (strcmp(name, "put") == 0) {
        run_put(target, res);
        return 1;
    }
    return 0;
}

int now68k_commands_dispatch(const char *name, const char *target, long id,
                              char *out, long cap, long *out_len)
{
    N68CmdResult res;
    long len;

    /* help answers here rather than through now68k_commands_run: its reply
     * is a ROW PER COMMAND, and an N68CmdResult holds one row. The console
     * renders the same k_docs list itself (conwin.c), so the two faces
     * still share the list even though they do not share this builder. */
    if (strcmp(name, "help") == 0) {
        len = run_help(target, id, out, cap);
        if (out_len != NULL) {
            *out_len = len;
        }
        return 1;
    }

    /* ps and vprobe answer here for the same reason help does: each
     * reply is a row per item and an N68CmdResult holds one row (two with
     * a state). Neither is a second implementation - both call the same
     * function now68k_commands_run would; only the renderer differs, which
     * is exactly the arrangement n68_cmdresult.h exists to preserve.
     *
     * A render that does not fit is answered, not swallowed: the caller is
     * blocked on a command.result the contract promises always comes, and
     * "the reply did not fit" is a true thing to say where silence is not.
     * The static assert in commands68.h is what makes that path
     * unreachable in this build. */
    if (strcmp(name, "ps") == 0) {
        len = run_ps(id, out, cap);
        if (out_len != NULL) {
            *out_len = len;
        }
        return 1;
    }

    if (strcmp(name, "vprobe") == 0) {
        n68_cmdresult_init(&res);
        if (run_vprobe(&res) == kVProbe68OK) {
            len = n68_vprobe_render_json(&g_vprobe, id, out, cap);
            if (len == 0) {
                now68k_log_num("cmd: vprobe table did not fit",
                                (long)g_vprobe.count);
                n68_cmdresult_set_error(&res, "vprobe-too-big",
                                        "the vprobe table did not fit one "
                                        "command.result");
                len = n68_cmdresult_render_json(&res, id, out, cap);
            }
        } else {
            len = n68_cmdresult_render_json(&res, id, out, cap);
        }
        if (out_len != NULL) {
            *out_len = len;
        }
        return 1;
    }

    if (!now68k_commands_run(name, target, &res)) {
        return 0;
    }

    len = n68_cmdresult_render_json(&res, id, out, cap);
    if (len == 0) {
        /* n68_cmdresult.c deliberately does not log - it has no idea which
         * command this was. This is the one place that does, so the line
         * the old finish_* builders wrote is not lost. */
        now68k_log("cmd: reply did not fit even the compact fallback");
    }
    if (out_len != NULL) {
        *out_len = len;
    }
    return 1;
}
