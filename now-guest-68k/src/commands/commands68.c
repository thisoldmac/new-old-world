/*
 * commands68.c - implementation of commands68.h: launch, quit and front.
 *
 * No malloc/NewPtr/NewHandle anywhere in this file - every buffer below is
 * a fixed, file-scope-sized local, matching the rest of now-guest-68k/src.
 *
 * STATIC BUDGET (stack per call, plus the BSS blocks):
 *   run_launch    name[200] + detail[160]                        = 360 B
 *   run_quit      QuitArgs(~40) + msg[80] + detail[160]           = 280 B
 *   run_front     name[32] + msg[80] + detail[160]               = 272 B
 *   run_vprobe    why[160]                                       = 160 B
 *   run_shot      N68ShotStats(~60) + N68ShotArgs(8) + why[160]    = 228 B
 *   run_ls        16 N68FileRow + path + root                    = ~1030 B
 *   dispatch      one N68CmdResult                               = 256 B
 *   g_vprobe      one N68VProbeTable, BSS                        = ~820 B
 *   g_rows        one N68CmdRows, BSS                            = ~1810 B
 * No two run_* are on the stack at once (dispatch calls exactly one), so
 * the deepest frame is dispatch's 256 plus run_ls's ~1030 = ~1290 B -
 * inside a 68K stack frame's normal headroom on a machine with ~1.7 MB
 * free. No recursion, no VLA.
 *
 * The BSS blocks are the vprobe row table, the one N68CmdRows a
 * table-shaped command fills, and the one census page a probe fills. All
 * three are BSS rather than locals precisely because this file's callers can be several levels deep by the time a
 * command runs (wire68.c -> dispatch, and a pumped nested dispatch on top
 * of that - proc68.c measured ~3.7 KB per level). See each one's comment
 * for why one instance is also the right number.
 *
 * No printf family (numfmt.h's now68k_fmt_append_str/long only, matching
 * wire68.c) - snprintf drags newlib's float formatting into a 384 KB
 * partition for conversions this file never performs.
 */
#include "commands68.h"

#include "census68.h"
#include "log.h"
#include "n68_census.h"
#include "n68_cmdresult.h"
#include "n68_fileenum.h"
#include "n68_filelist.h"
#include "n68_proclist.h"
#include "n68_vprobe.h"
#include "numfmt.h"
#include "n68_shot.h"
#include "n68_shotdiag.h"
#include "proc68.h"
#include "shot68.h"
#include "shotstage68.h"
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
/* Mirrors proc_quit_args.c's grammar exactly (now/now-guest-ppc/src/
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
     * guest's run_quit (now/now-guest-ppc/src/commands/commands.c, branch
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

/* ---- front ------------------------------------------------------------------
 *
 * quit's gentler sibling, and a much smaller parser: `front` has no flags,
 * so the whole rest of the line is the name and there is nothing that
 * could be mistaken for one. (That is the entire reason quit's grammar
 * puts flags FIRST - a trailing --all is indistinguishable from the last
 * word of "Apple File Security". With no flags there is no such hazard.)
 */

/* The name, trimmed and unquoted. Returns 0 with a sentence in `msg`. */
static int front_parse(const char *arg, char *out, long cap, char *msg,
                       long msg_cap)
{
    const char *p = arg != NULL ? arg : "";
    long len;

    while (*p == ' ' || *p == '\t') {
        ++p;
    }
    len = (long)strlen(p);
    while (len > 0 && (p[len - 1] == ' ' || p[len - 1] == '\t')) {
        --len;   /* a trailing space is typing, not part of the name */
    }
    if (len >= 2 && p[0] == '"' && p[len - 1] == '"') {
        ++p;
        len -= 2;
    }
    if (len == 0) {
        bounded_strcpy(msg, msg_cap,
                       "front: what? (the name of a running process)");
        return 0;
    }
    if (len >= cap) {
        bounded_strcpy(msg, msg_cap,
                       "front: no process name is longer than 31 "
                       "characters");
        return 0;
    }
    bounded_copy_n(out, cap, p, len);
    return 1;
}

static void run_front(const char *target, N68CmdResult *res)
{
    char name[kQuitNameMax];
    char msg[kMsgMax];
    char detail[kDetailCap];
    ProcFrontOutcome outcome;
    const char *state;
    const char *code;

    if (!front_parse(target, name, (long)sizeof name, msg, sizeof msg)) {
        n68_cmdresult_set_error(res, "front-bad-args", msg);
        return;
    }

    outcome = proc_front_named(name, kProcFrontWaitSecs * 60L, detail,
                                sizeof detail);

    /* ok:true for kProcFrontDone ALONE. The three that follow each mean
     * the caller cannot rely on that window being in front, and this
     * reply's ok bit promises exactly that one thing - the same discipline
     * run_quit applies to "is it gone". Note kProcFrontNotRunning is
     * ok:FALSE where quit's kProcNotRunning is ok:true: quit was asked to
     * produce "not running" and it already held; nothing can front a
     * process that is not there (proc68.h). Each case breaks, so nothing
     * depends on enum ordering. */
    switch (outcome) {
    case kProcFrontDone:
        state = "fronted";
        code = NULL;
        break;
    case kProcFrontUnconfirmed:
        state = "unconfirmed";
        code = "front-unconfirmed";
        break;
    case kProcFrontNotRunning:
        state = "not-running";
        code = "front-not-running";
        break;
    case kProcFrontAmbiguous:
        state = "ambiguous";
        code = "front-ambiguous";
        break;
    case kProcFrontRefused:
        state = "refused";
        code = "front-refused";
        break;
    case kProcFrontBadArgs:
    default:
        state = "bad-args";
        code = "front-bad-args";
        break;
    }

    now68k_log_num(code == NULL ? "cmd: front ok" : "cmd: front not-front",
                    (long)outcome);

    if (code != NULL) {
        n68_cmdresult_set_error(res, code, detail);
        return;
    }
    n68_cmdresult_set_ok2(res, "front", "Front", detail, "Outcome", state);
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

/* ---- screenshot ------------------------------------------------------------ */

/* SLICE ONE: the picture lands on the guest's own desktop and what comes
 * back is the measurement. Nothing about it is a row array - it is a
 * sentence and a handful of numbers, which is exactly what an
 * N68CmdResult holds - so it goes through now68k_commands_run like launch
 * and quit, and the console gets it by delegation with nobody having to
 * add anything to conwin.c. That is deliberate: three commands already
 * answer inside now68k_commands_dispatch because their replies are a row
 * per item, and docs/command-parity.md says plainly that a fourth should
 * not be another arm. This one does not need to be.
 *
 * The failure statuses are collapsed into two codes and a sentence, on
 * vprobe's argument: a caller that asked for a capture and got none needs
 * to know whether the machine was BUSY (retry) or REFUSED (do something
 * about the screen, the disk, or the depth), and the sentence says which
 * of the ways. An empty result dressed as a success is the one answer a
 * measurement command must never give. */
static void run_shot(const char *target, N68CmdResult *res)
{
    N68ShotArgs args;
    N68ShotStats stats;
    char why[kDetailCap];
    Shot68Status status;

    why[0] = '\0';
    n68_shot_args_parse(target, &args);
    status = shot68_capture(&args, &stats, why, (long)sizeof why);
    if (status != kShot68OK) {
        now68k_log_num("cmd: screenshot refused", (long)status);
        n68_cmdresult_set_error(res, status == kShot68Busy
                                         ? "screenshot-busy"
                                         : "screenshot-refused",
                                why[0] != '\0' ? why
                                               : "screenshot could not "
                                                 "capture this screen");
        return;
    }
    now68k_log_num("cmd: screenshot ok", stats.pict_bytes);
    n68_shot_summary(&stats, res);
}

/* ---- help ------------------------------------------------------------------- */

/* What THIS Mac serves - and it says exactly what it serves.
 *
 * The other side keeps no command list: there are two guests with different
 * tables (the PowerPC Carbon guest implements sixteen commands, this one
 * implements four through now68k_commands_run - launch, quit, front, put -
 * plus help, ps and vprobe, which each build a row per item and so answer
 * at dispatch), so a console-side list would be wrong for both. Discovery is therefore a
 * request like any other, and the honest answer from here is a short one.
 * It is also the ONLY thing the host console's Tab completion has to go on,
 * which is the second reason a command missing from this table is a command
 * a person cannot find. The PowerPC guest answers the same command from its
 * own table (now-guest-ppc/src/commands/cmd_help.c); this table is deliberately separate
 * rather than shared, because the two applications share no source - they
 * meet only on the wire, and the contract is the thing they hold in common.
 *
 * The trailing note row is not decoration. A human reading a short list
 * needs to know whether that is all this machine HAS or all it would admit
 * to; saying "everything else answers unknown-command" is the difference
 * between a short list and a suspicious one. */
static const N68CommandDoc k_docs[] = {
    { "launch", "open an application on this Mac",
      "launch <name | full path>" },
    { "quit", "ask an application on this Mac to quit",
      "quit [--all] [--wait N | --no-wait] <name>" },
    { "front", "bring an application on this Mac forward",
      "front <name>" },
    { "help", "list the commands this Mac serves",
      "help [command]" },
    { "ps", "the processes running on this Mac", "ps" },
    { "vprobe", "measure this Mac's VRAM read cost",
      "vprobe (no arguments; wants a still screen)" },
    { "screenshot", "capture this Mac's screen to its desktop",
      "screenshot [--depth 8] [--no-save]" },
    { "shotdiag", "stage a capture and report where it read from",
      "shotdiag (no arguments; wants a still screen)" },
    { "put", "send a file from this Mac to the host", "put <file name>" },
    { "ls", "list a folder in this Mac's share", "ls [folder]" },
    /* The usage line is one row of an N68CmdResult and so is capped at
     * kN68CmdStateCap (48). The fourteen probe names do not fit that and
     * are not put there truncated: a grammar cut off mid-list is worse
     * than a short one, because a person would type what they could see.
     * `census` with no argument runs `overview`, which is the discovery
     * path the contract already specifies. */
    { "census", "one hardware-census probe of this Mac",
      "census [probe]; no probe runs overview" },
    { "cancel", "stop the file transfer in flight, either direction",
      "cancel (no arguments)" },
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

/* ---- `ls`: the fourth row-array command, and the first that is not an
 * exemption -----------------------------------------------------------------
 *
 * docs/command-parity.md ends with the ruling this obeys: three commands
 * answer inside now68k_commands_dispatch because an N68CmdResult holds one
 * row, and "a fourth should not be another arm... the fix is a result type
 * that holds rows". N68CmdRows (n68_cmdresult.h) is that type, and `ls`
 * goes through it - so conwin.c reaches this verb by DELEGATING, exactly
 * the way it reaches `launch`, and there is no fourth strcmp in the
 * console's dispatch to drift from this one.
 *
 * `ls` is to file.list what `ps` is to process.list, and the contract says
 * so in the verb's own description. One enumeration underneath both:
 * n68_fileenum.c walks the catalog, n68_filelist.c renders that walk as
 * file.listing for the host's Files module and as these rows for anyone
 * typing - the host's console (a dumb shell that knows no message families
 * and can only type) or the PowerBook's own.
 *
 * One page, and it says when there is more. The contract gives
 * command.result no cursor and a console has none to send back, so the
 * full folder is a file.list away - which is the same trade `ps` makes
 * against process.list. */
static N68CmdRows g_rows;

/* The page `census` fills, in BSS for g_rows' reason (~1.1 KB is too much
 * for a stack frame the command path can re-enter) and separate from
 * wire68.c's own page on purpose: that one is filled from inside the frame
 * reader, this one from a console line, and one buffer shared between them
 * would be a page half-overwritten by a request that arrived while a human
 * was reading. */
static N68CensusPage g_census;

/* This module PROMISES its callers NOW68K_COMMAND_RESULT_CAP (commands68.h)
 * and the shipping caller hands over the larger NOW68K_CONTROL_SEND_CAP, so
 * this is the number that has to hold a table with a row in it and still be
 * able to say what it dropped. The 160-vs-512 command.result bug was
 * exactly a build where two limits disagreed and only the bigger one was
 * ever exercised. */
_Static_assert(NOW68K_COMMAND_RESULT_CAP >= NOW68K_CMDROWS_MIN_CAP,
               "a table reply must fit a command.result buffer with at "
               "least one row in it and still be able to say what it "
               "left out");

static void run_ls(const char *target, N68CmdRows *out)
{
    N68FileRow rows[NOW68K_FILELIST_MAX_ROWS];
    /* +2, not +1: bounded_strcpy truncates to fit, so a buffer of exactly
     * cap+1 makes strlen() top out AT the cap and the over-long check
     * below could never fire - a person's long path would list the wrong
     * folder rather than be refused. Same reasoning as the wire's
     * handle_file_list. */
    char path[NOW68K_FILELIST_PATH_MAX + 2];
    char root[NOW68K_FILELIST_ROOT_MAX + 1];
    long count;
    int more = 0;

    /* The whole line is the path: an HFS name has spaces in it and quoting
     * them would be a second grammar for a console to get wrong. The
     * PowerPC guest's run_ls reads it the same way. */
    path[0] = '\0';
    if (target != NULL) {
        bounded_strcpy(path, (long)sizeof path, target);
    }
    if (strlen(path) > NOW68K_FILELIST_PATH_MAX) {
        n68_cmdrows_set_error(out, n68_fileenum_code_word(kN68EnumBadPath),
                              n68_fileenum_code_reason(kN68EnumBadPath));
        return;
    }

    count = n68_fileenum_page(path, 1, rows,
                              (long)NOW68K_FILELIST_MAX_ROWS, &more);
    if (count < 0) {
        N68EnumCode rc = (N68EnumCode)(-count);

        /* The same code and the same sentence the wire's file.refuse
         * carries for this failure. A person typing `ls Foo` and a host
         * sending file.list should not be told two different stories about
         * one folder. */
        n68_cmdrows_set_error(out, n68_fileenum_code_word(rc),
                              n68_fileenum_code_reason(rc));
        return;
    }

    root[0] = '\0';
    n68_fileenum_root_name(root, (long)sizeof root);
    n68_filelist_rows(path, root[0] != '\0' ? root : NULL, rows, count,
                      more, out);
}

/* ---- `shotdiag`: one metal pass, and the machine is answerable ------------
 *
 * A capture taken on the PowerBook 180c arrives at the host as structured
 * noise while the same lane crosses byte-accurately on the Quadra 800
 * emulator. Nothing here can settle that; only that machine can, and it is
 * in another room. So this verb exists to make ONE trip enough:
 * n68_shotdiag.h states the two surviving hypotheses and the single
 * observation that separates them.
 *
 * IT RUNS THE LIVE PATH, not a copy of it. shotstage68_diagnose() IS
 * shotstage68_write() - same walk, same PackBits, same scratch file - with
 * the facts recorded on the way past. A diagnostic built as its own
 * routine could only ever clear the routine it is, which is how the
 * previous pass came to clear shotstage68.c by inspection and prove
 * nothing.
 *
 * The scratch file is discarded afterwards. This verb answers a question;
 * it does not arm a transfer, and 65 KB left on a 4 MB disk is the failure
 * kShotStageLeaf's own note warns about.
 *
 * A row array rather than an N68CmdResult, and therefore through
 * now68k_commands_run_rows and NOT a fifth arm in the dispatch: eleven
 * [label, value] pairs is a table, and docs/command-parity.md's ruling is
 * that a table-shaped answer takes the rows seam so the console reaches it
 * by delegating. conwin.c is untouched by this command's existence. */
static void run_shotdiag(N68CmdRows *out)
{
    ShotStage68 staged;
    N68ShotDiag diag;
    char why[kDetailCap];
    ShotStage68Status status;

    why[0] = '\0';
    n68_shotdiag_init(&diag);
    status = shotstage68_diagnose(&staged, &diag, why, (long)sizeof why);
    shotstage68_discard();
    if (status != kShotStage68OK) {
        now68k_log_num("cmd: shotdiag refused", (long)status);
        /* ONE code, not `screenshot`'s two, and that is a deliberate
         * difference rather than a copy made carelessly. `screenshot`
         * splits busy from refused because Shot68Status tells them apart.
         * ShotStage68Status does not: kShotStage68File is returned both
         * for "a capture is already being staged" and for a disk that said
         * no, and a code that guessed between them would be a retry hint
         * invented out of nothing. The sentence carries which. */
        n68_cmdrows_set_error(out, "shotdiag-refused",
                              why[0] != '\0' ? why
                                             : "shotdiag could not stage a "
                                               "capture on this Mac");
        return;
    }
    now68k_log_num("cmd: shotdiag ok", diag.staged_bytes);
    out->ok = 1;
    bounded_strcpy(out->key, sizeof out->key, "shotdiag");
    n68_shotdiag_rows(&diag, out);
}

/* The other end of `put`, and of a push arriving - one verb for both,
 * because the lane is one transfer wide and there is only ever one thing
 * to stop. wire68.c owns the doing; this is a renderer.
 *
 * It takes no argument on purpose. The wire's file.cancel names a
 * transfer id, and a person has no way to know one and no second
 * transfer to confuse it with - asking them for it would be asking for
 * a number the machine already knows.
 *
 * A quiet machine answers ok:false "nothing-to-cancel" rather than
 * pretending. Typing `cancel` at a machine that is not transferring
 * anything is a reasonable thing to have done - usually because the
 * last one already ended - and the useful reply says so. */
/* ---- `census`: one probe, one page, for a person --------------------------
 *
 * The console face of the same census the host pages through
 * censusExchange, and the same implementation underneath - census68.c
 * gathers, and n68_census.c renders that page either as a `census.report`
 * for the wire or as these rows. The contract's own verb description says
 * what the collapse is: the wire's [name, raw, meaning] triple becomes
 * [name, meaning] for a text surface, and the raw value folds into the
 * meaning column when a row has no decoded form, so nothing is dropped on
 * the way to a human.
 *
 * The rows seam rather than a sixth dispatch arm, for `ls`'s reason: a
 * table-shaped answer goes through now68k_commands_run_rows so the console
 * reaches it by delegating, and n68_exec.c is untouched by this verb's
 * existence.
 *
 * ONE PAGE. The contract gives command.result no cursor and a console has
 * none to send back, so a probe with more rows than fit says so in its
 * trailing status row and the full walk is a census.request away - the
 * same trade `ps` makes against process.list. */
static void run_census(const char *target, N68CmdRows *out)
{
    char probe[kN68CensusProbeCap];

    /* The whole line is the probe name. No probe in the registry has a
     * space in it, but taking the line whole is what every other verb here
     * does, and a second grammar for one command is how a console learns
     * to disagree with itself. */
    probe[0] = '\0';
    if (target != NULL) {
        bounded_strcpy(probe, (long)sizeof probe, target);
    }
    if (!now68k_census_gather(probe, 0, &g_census)) {
        /* ok:false, never a protocol error, and never `absent`: the
         * machine was not asked anything here - a name was not found. */
        n68_cmdrows_set_error(out, "unknown-probe",
                              "no census probe by that name - try `census` "
                              "with no argument");
        return;
    }
    out->ok = 1;
    bounded_strcpy(out->key, sizeof out->key, "census");
    n68_census_rows(probe[0] != '\0' ? probe : "overview", &g_census, out);
}

static void run_cancel(N68CmdResult *res)
{
    char what[96];

    if (!now68k_wire_cancel_transfer(what, (long)sizeof what)) {
        n68_cmdresult_set_error(res, "nothing-to-cancel",
                                "no file is moving in either direction");
        return;
    }
    res->ok = 1;
    bounded_strcpy(res->key, sizeof res->key, "cancel");
    bounded_strcpy(res->label, sizeof res->label, "cancel");
    bounded_strcpy(res->text, sizeof res->text, what);
}

/* ---- dispatch --------------------------------------------------------------- */

const N68CmdRows *now68k_commands_run_rows(const char *name,
                                            const char *target)
{
    if (name == NULL) {
        return NULL;
    }
    if (strcmp(name, "ls") == 0) {
        n68_cmdrows_init(&g_rows);
        run_ls(target, &g_rows);
        return &g_rows;
    }
    if (strcmp(name, "shotdiag") == 0) {
        n68_cmdrows_init(&g_rows);
        run_shotdiag(&g_rows);
        return &g_rows;
    }
    if (strcmp(name, "census") == 0) {
        n68_cmdrows_init(&g_rows);
        run_census(target, &g_rows);
        return &g_rows;
    }
    return NULL;
}

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
    if (strcmp(name, "front") == 0) {
        run_front(target, res);
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
    /* screenshot needs no exemption and gets none: both faces render the
     * same two rows of the same capture, from here. */
    if (strcmp(name, "screenshot") == 0) {
        run_shot(target, res);
        return 1;
    }
    if (strcmp(name, "put") == 0) {
        run_put(target, res);
        return 1;
    }
    if (strcmp(name, "cancel") == 0) {
        run_cancel(res);
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

    /* The table-shaped commands, which are NOT an exemption: they run
     * through a published seam the console reaches too, so this is the
     * same run-then-render arrangement as the one-row case below with a
     * different renderer, not a fourth arm. See run_ls above. */
    {
        const N68CmdRows *rows = now68k_commands_run_rows(name, target);

        if (rows != NULL) {
            len = n68_cmdrows_render_json(rows, id, out, cap);
            if (len == 0) {
                /* Unreachable at NOW68K_COMMAND_RESULT_CAP (the static
                 * assert above), but a caller blocked on a command.result
                 * the contract promises always comes must never be left
                 * with silence. */
                now68k_log("cmd: table reply did not fit");
                n68_cmdresult_set_error(&res, "reply-too-big",
                                        "the table did not fit one "
                                        "command.result");
                len = n68_cmdresult_render_json(&res, id, out, cap);
            }
            if (out_len != NULL) {
                *out_len = len;
            }
            return 1;
        }
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
