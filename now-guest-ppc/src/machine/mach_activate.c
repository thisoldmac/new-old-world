/* `activate` - front a process by its serial number. The Toolbox half;
   the parse and the verdict are in mach_activate_args.c, where a host cc
   can watch them fail. See mach_verbs.h for the registration. */

#include <Carbon.h>
#include <stdio.h>
#include <string.h>

#include "cmd_line.h"
#include "mach_activate_args.h"
#include "mach_reply.h"
#include "mach_verbs.h"
#include "nowlog.h"
#include "proc_actions.h"
#include "proc_roster.h"
#include "wire.h"

/* Short on purpose, and the same two seconds `front` waits: a process
   switch that has not happened in two seconds of yielded time is not
   going to. */
#define kMachActivateWaitSecs 2

/* The yield that used to live here went with the confirm loop:
   now_proc_front_confirm pumps the wire while it waits, exactly as this
   did, and one waiting loop is the point of the change. */

static void pascal_to_c(ConstStr255Param p, char *out, long cap)
{
    long n = (p != NULL) ? (long)p[0] : 0;

    if (n > cap - 1) {
        n = cap - 1;
    }
    if (n > 0) {
        memcpy(out, (const char *)p + 1, (size_t)n);
    }
    out[n] = '\0';
}

void now_mach_run_activate(const char *request_json, long id,
                           char *out, long cap)
{
    NowMachPsnArg          arg;
    NowMachActivateFacts   facts;
    NowMachActivateOutcome outcome;
    ProcessSerialNumber    psn;
    ProcessInfoRec         info;
    Str63                  name;
    char                   line[128];
    char                   shown[64];
    char                   psn_text[48];

    memset(&facts, 0, sizeof facts);
    line[0] = '\0';
    (void)now_cmd_line(request_json, line, (long)sizeof line);
    if (!now_mach_psn_parse(request_json, line, &arg)) {
        now_mach_reply_error(out, cap, id,
                             now_mach_activate_code(kNowMachActivateBadArgs),
                             now_mach_activate_message(
                                 kNowMachActivateBadArgs));
        return;
    }

    psn.highLongOfPSN = (unsigned long)arg.hi;
    psn.lowLongOfPSN = (unsigned long)arg.lo;
    snprintf(psn_text, sizeof psn_text, "%lu.%lu",
             (unsigned long)arg.hi, (unsigned long)arg.lo);
    shown[0] = '\0';

    memset(&info, 0, sizeof info);
    info.processInfoLength = (long)sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    if (GetProcessInformation(&psn, &info) == noErr) {
        facts.found = 1;
        facts.background_only =
            now_proc_kind_classify((unsigned long)info.processType,
                                   (unsigned long)info.processSignature,
                                   (unsigned long)info.processMode)
            == kNowProcKindBackground;
        pascal_to_c(name, shown, (long)sizeof shown);
    }
    if (facts.found) {
        facts.was_front = now_proc_is_frontmost(&psn) ? 1 : 0;
    }

    outcome = now_mach_activate_verdict(&facts);
    if (outcome == kNowMachActivateNoSuchProcess
        || outcome == kNowMachActivateBackgroundOnly
        || outcome == kNowMachActivateAlreadyFront) {
        /* Nothing is asked of the machine in any of these. Only the last
           one is a success, and the verdict already knows which. */
        if (!now_mach_activate_is_front(outcome)) {
            now_log(kLogWarn, "mach", "#%ld activate %s [%s]", id, psn_text,
                    now_mach_activate_code(outcome));
            now_mach_reply_error(out, cap, id,
                                 now_mach_activate_code(outcome),
                                 now_mach_activate_message(outcome));
            return;
        }
    } else {
        /* THE ONE SetFrontProcess IN THIS GUEST. `front` reaches the same
           function with a PSN it found by name; this one was handed the
           PSN. Two addressing modes, one implementation. */
        facts.set_called = 1;
        switch (now_proc_front_confirm(&psn,
                                       (unsigned long)kMachActivateWaitSecs
                                       * 60)) {
        case kProcFrontConfirmed:
            facts.confirmed_front = 1;
            break;
        case kProcFrontAccepted:
            break;
        case kProcFrontSetRefused:
            /* The verdict reads set_err, not an errno, so any non-zero
               says the same thing it always said. */
            facts.set_err = -1;
            break;
        }
        outcome = now_mach_activate_verdict(&facts);
        if (!now_mach_activate_is_front(outcome)) {
            /* Unconfirmed is a failure REPLY here, the way `front`'s is,
               and for the reason proc_actions.h gives: a caller whose
               next step assumes that window is up must not read an
               accepted request as a completed switch. The code says
               which of the two it was, so nothing is lost by the
               envelope being ok:false. */
            now_log(kLogWarn, "mach", "#%ld activate %s [%s] (err %d)", id,
                    psn_text, now_mach_activate_code(outcome), facts.set_err);
            now_mach_reply_error(out, cap, id,
                                 now_mach_activate_code(outcome),
                                 now_mach_activate_message(outcome));
            return;
        }
    }

    {
        NowMachRows rows;

        now_mach_rows_reset(&rows);
        now_mach_row(&rows, "Process", shown[0] != '\0' ? shown : "(unnamed)");
        now_mach_row(&rows, "Serial", psn_text);
        now_mach_row(&rows, "Outcome", now_mach_activate_code(outcome));
        /* The claim, and its evidence, as separate rows - a re-read is
           not the same fact as an accepted request, and this surface has
           to be readable by something that will act on the difference. */
        now_mach_row(&rows, "Frontmost", "yes, re-read from the machine");
        now_mach_row(&rows, "Note", now_mach_activate_message(outcome));
        now_log(kLogInfo, "mach", "#%ld activate %s [%s] %.31s", id, psn_text,
                now_mach_activate_code(outcome), shown);
        now_mach_reply_rows(out, cap, id, "activate", &rows);
    }
}
