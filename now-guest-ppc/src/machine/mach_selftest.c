/* `actselftest` - prove the act plane's trap calling convention inside
   one process. The Toolbox half: bind a target, fill the cell, submit,
   and hand the answer to mach_selftest_report.c, which is where the
   judgement lives and where a host cc can watch it fail.

   This file is deliberately thin, the way act_client.c is thin: it does
   the things only a Macintosh can do and decides nothing. See
   mach_verbs.h for the registration and for why the plane serving this
   op with no caller was worth fixing. */

#include <Carbon.h>
#include <stdio.h>
#include <string.h>

#include "act_client.h"
#include "cmd_line.h"
#include "mach_activate_args.h"
#include "mach_reply.h"
#include "mach_selftest_report.h"
#include "mach_verbs.h"
#include "nowlog.h"
#include "peek_table.h"

/* Off the stack, for the same reason act_cmds.c keeps its two off it. */
static NowActTarget   g_target;
static NowPeekActCell g_snap;

void now_mach_run_actselftest(const char *request_json, long id,
                              char *out, long cap)
{
    NowMachPsnArg          arg;
    NowMachSelfTestReading reading;
    NowMachSelfTestVerdict verdict;
    NowPeekActCell        *cell;
    NowActStatus           st;
    ProcessSerialNumber    psn;
    char                   line[128];
    char                   who[64];
    NowMachRows            rows;

    line[0] = '\0';
    (void)now_cmd_line(request_json, line, (long)sizeof line);

    st = now_act_ready();
    if (st != kNowActOk) {
        now_mach_reply_error(out, cap, id, now_act_status_code(st),
                             now_act_status_message(st));
        return;
    }

    /* A PSN is optional: absent means the front process, which is what a
       person at a console means and what upstream's equivalent defaulted
       to. When it IS given, it is the same whole-or-nothing parse
       `activate` uses - half a PSN would silently test a different
       process, and "the ABI holds" about the wrong process is worse than
       no answer. */
    if (now_mach_psn_parse(request_json, line, &arg)) {
        psn.highLongOfPSN = (unsigned long)arg.hi;
        psn.lowLongOfPSN = (unsigned long)arg.lo;
        st = now_act_open(&psn, &g_target);
    } else if (now_mach_psn_offered(request_json, line)) {
        now_mach_reply_error(out, cap, id,
                             now_mach_activate_code(kNowMachActivateBadArgs),
                             "actselftest takes a whole process serial "
                             "number, or none at all, which means the front "
                             "process");
        return;
    } else {
        st = now_act_open(NULL, &g_target);
    }
    if (st != kNowActOk) {
        now_mach_reply_error(out, cap, id, now_act_status_code(st),
                             now_act_status_message(st));
        return;
    }

    cell = now_act_cell();
    if (cell == NULL) {
        now_mach_reply_error(out, cap, id,
                             now_act_status_code(kNowActNoExtension),
                             now_act_status_message(kNowActNoExtension));
        return;
    }

    /* The op, and nothing else. Every field the test needs -
       menu_id, item_index, selftest_want, the negative arm point - is
       written by the hook itself, in the target's own context
       (act_serve_selftest). Writing them from here would make this
       application the source of the answer it is checking, which is
       precisely the instrument-agrees-with-itself failure the test
       exists to break. */
    cell->op = kNowPeekActOpSelfTest;

    st = now_act_submit(g_target.a5, &g_snap);
    now_act_withdraw();

    now_mach_selftest_read(st == kNowActOk ? &g_snap : NULL, (int)st,
                           &reading);
    verdict = now_mach_selftest_verdict(&reading);

    if (verdict == kNowMachSelfTestUnreached) {
        /* The act client's own vocabulary names these better than this
           verb can - no extension, stale, dark, no target, no anchor,
           never pumped - so it answers with that rather than flattening
           six conditions into one word of its own.

           EXCEPT when the plane SERVED and refused. `kNowActRefused`
           means the resident took the request, ran it in the target's
           context, and set a status other than Done - and the cell it
           filled says WHY in `error`, which the status cannot. Reporting
           the status alone turns "the patch was never installed in that
           process" and "the patch answered and the caller read junk"
           into one word, `act-refused`, and that is exactly the sentence
           that made this verb useless as an instrument on 2026-08-02: it
           refused against SimpleText and the Finder while abi-agreeing
           against this application, and the answer to why was sitting in
           the cell, discarded. now_act_submit snapshots BEFORE it judges
           the status, so `g_snap` is populated on this path. */
        if (st == kNowActRefused && g_snap.error != kNowPeekActErrNone) {
            now_log(kLogWarn, "mach", "#%ld actselftest refused [%s]", id,
                    now_act_error_code(g_snap.error));
            now_mach_reply_error(out, cap, id,
                                 now_act_error_code(g_snap.error),
                                 now_act_error_message(g_snap.error));
            return;
        }
        now_log(kLogWarn, "mach", "#%ld actselftest unreached [%s]", id,
                now_act_status_code(st));
        now_mach_reply_error(out, cap, id, now_act_status_code(st),
                             now_act_status_message(st));
        return;
    }

    who[0] = '\0';
    {
        long n = (long)g_target.name[0];

        if (n > (long)sizeof who - 1) {
            n = (long)sizeof who - 1;
        }
        if (n > 0) {
            memcpy(who, (const char *)g_target.name + 1, (size_t)n);
        }
        who[n > 0 ? n : 0] = '\0';
    }

    now_mach_rows_reset(&rows);
    now_mach_row(&rows, "Process", who[0] != '\0' ? who : "(unnamed)");
    now_mach_rowf(&rows, "A5", "0x%08lX", (unsigned long)g_target.a5);
    now_mach_row(&rows, "Verdict", now_mach_selftest_code(verdict));
    /* BOTH numbers, always, including on the good path. The mismatch is
       unreadable anywhere else in the system, and a reader who cannot
       see the pair has to take this verb's word for it. */
    now_mach_rowf(&rows, "Answered", "0x%08lX", reading.want);
    now_mach_rowf(&rows, "Read back", "0x%08lX", reading.got);
    now_mach_row(&rows, "Mechanism",
                 "a real MenuSelect at (0,0), made and answered inside the "
                 "target process");
    now_mach_row(&rows, "Note", now_mach_selftest_message(verdict));

    now_log(now_mach_selftest_proves_abi(verdict) ? kLogInfo : kLogWarn,
            "mach", "#%ld actselftest a5=%lu [%s] want=%08lX got=%08lX", id,
            (unsigned long)g_target.a5, now_mach_selftest_code(verdict),
            reading.want, reading.got);

    if (!now_mach_selftest_proves_abi(verdict)) {
        char detail[560];

        /* An unproven convention is not a successful call. A caller that
           reads ok:true and moves on is exactly the reader this whole
           instrument exists to protect - and the two numbers travel WITH
           the failure, because a reader who cannot see the pair has only
           this verb's word for the verdict. */
        snprintf(detail, sizeof detail,
                 "%s (answered 0x%08lX; the caller read 0x%08lX)",
                 now_mach_selftest_message(verdict), reading.want,
                 reading.got);
        now_mach_reply_error(out, cap, id, now_mach_selftest_code(verdict),
                             detail);
        return;
    }
    now_mach_reply_rows(out, cap, id, "actselftest", &rows);
}
