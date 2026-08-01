/* `activate` - the parse and the verdict. See mach_activate_args.h. */

#include "mach_activate_args.h"

#include <stddef.h>

#include "json.h"

/* Read one unsigned 32-bit number out of `p`, which may be a JSON number
   or a JSON string holding one - the host writes the PSN halves as
   numbers, an agent may quote them, and a person types them bare.

   Written out rather than reached for through strtoul because the guest
   compiles this for a 32-bit long: strtoul's saturation at ULONG_MAX
   would turn an over-long number into 0xFFFFFFFF, which is a DIFFERENT
   process id rather than a rejected one. Overflow is refused here
   instead. */
static int scan_u32(const char *p, unsigned long *out, const char **end)
{
    unsigned long v = 0;
    int           digits = 0;

    if (p == NULL) {
        return 0;
    }
    while (*p == ' ' || *p == '\t') {
        p++;
    }
    if (*p == '"') {
        p++;
    }
    while (*p >= '0' && *p <= '9') {
        unsigned long d = (unsigned long)(*p - '0');

        if (v > (0xFFFFFFFFUL - d) / 10UL) {
            return 0;                   /* wider than a PSN half */
        }
        v = v * 10UL + d;
        digits++;
        p++;
    }
    if (digits == 0) {
        return 0;
    }
    if (out != NULL) {
        *out = v;
    }
    if (end != NULL) {
        *end = p;
    }
    return 1;
}

int now_mach_psn_parse(const char *request_json, const char *line,
                       NowMachPsnArg *out)
{
    const char   *hi_v;
    const char   *lo_v;
    unsigned long hi = 0;
    unsigned long lo = 0;
    const char   *p;

    if (out == NULL) {
        return 0;
    }
    out->hi = 0;
    out->lo = 0;
    out->present = 0;

    /* The typed caller wins, and BOTH halves must be there: half a PSN
       is not a process, and defaulting the other half to zero would
       silently address a different one. */
    hi_v = now_json_value(request_json, "serialHi");
    lo_v = now_json_value(request_json, "serialLo");
    if (hi_v != NULL && lo_v != NULL) {
        if (!scan_u32(hi_v, &hi, NULL) || !scan_u32(lo_v, &lo, NULL)) {
            return 0;
        }
        out->hi = hi;
        out->lo = lo;
        out->present = (hi != 0 || lo != 0);
        return out->present;
    }
    if (hi_v != NULL || lo_v != NULL) {
        return 0;                       /* half a PSN is not a PSN */
    }

    /* The human spelling: two whole numbers on the line, high first,
       the way every reader in this project prints a PSN. */
    if (line == NULL) {
        return 0;
    }
    p = line;
    if (!scan_u32(p, &hi, &p)) {
        return 0;
    }
    if (!scan_u32(p, &lo, NULL)) {
        return 0;
    }
    out->hi = hi;
    out->lo = lo;
    out->present = (hi != 0 || lo != 0);
    return out->present;
}

NowMachActivateOutcome now_mach_activate_verdict(
    const NowMachActivateFacts *f)
{
    if (f == NULL) {
        return kNowMachActivateBadArgs;
    }
    if (!f->found) {
        return kNowMachActivateNoSuchProcess;
    }
    /* Read BEFORE background-only, because a process that is already
       frontmost demonstrably can be: a flag that disagrees with the
       machine loses to the machine. */
    if (f->was_front) {
        return kNowMachActivateAlreadyFront;
    }
    if (f->background_only) {
        return kNowMachActivateBackgroundOnly;
    }
    if (!f->set_called || f->set_err != 0) {
        return kNowMachActivateRefused;
    }
    /* SetFrontProcess returning noErr means the switch was SCHEDULED. On
       a cooperative system it happens when we yield, so the re-read is
       the only thing that can tell a completed switch from an accepted
       request - the same distinction proc_actions.h makes for `front`,
       and for the same reason. */
    return f->confirmed_front ? kNowMachActivateDone
                              : kNowMachActivateUnconfirmed;
}

int now_mach_activate_is_front(NowMachActivateOutcome o)
{
    return o == kNowMachActivateDone || o == kNowMachActivateAlreadyFront;
}

const char *now_mach_activate_code(NowMachActivateOutcome o)
{
    switch (o) {
    case kNowMachActivateDone:           return "fronted";
    case kNowMachActivateAlreadyFront:   return "already-front";
    case kNowMachActivateUnconfirmed:    return "activate-unconfirmed";
    case kNowMachActivateNoSuchProcess:  return "activate-no-such-process";
    case kNowMachActivateBackgroundOnly: return "activate-background-only";
    case kNowMachActivateRefused:        return "activate-refused";
    case kNowMachActivateBadArgs:        return "bad-request";
    default:                             break;
    }
    return "bad-request";
}

const char *now_mach_activate_message(NowMachActivateOutcome o)
{
    switch (o) {
    case kNowMachActivateDone:
        return "that process is frontmost, confirmed by re-reading which "
               "process the machine says is in front";
    case kNowMachActivateAlreadyFront:
        return "that process was already frontmost; nothing was asked of "
               "the machine";
    case kNowMachActivateUnconfirmed:
        return "the switch was accepted and is not observable yet - a "
               "cooperative switch lands when this application yields, so "
               "ask again rather than reading this as done";
    case kNowMachActivateNoSuchProcess:
        return "no process with that serial number is running; a PSN is "
               "only meaningful while the process it names is alive, so "
               "observe the list again";
    case kNowMachActivateBackgroundOnly:
        return "that process declares itself background-only and cannot "
               "be brought to the front at all";
    case kNowMachActivateRefused:
        return "the Process Manager refused to bring that process "
               "forward";
    case kNowMachActivateBadArgs:
        return "activate needs a whole process serial number: serialHi "
               "and serialLo together, or both numbers on the line";
    default:
        break;
    }
    return "activate needs a whole process serial number: serialHi and "
           "serialLo together, or both numbers on the line";
}
