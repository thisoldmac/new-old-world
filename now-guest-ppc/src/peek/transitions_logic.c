/*
 * transitions_logic.c - see transitions_logic.h for why this half is
 * separate from the Toolbox one.
 */

#include "transitions_logic.h"

#include <string.h>

void now_transitions_fill_status(const NowEventBlock *block,
                                 NowEventU32 cursor, NowEventU32 now_ticks,
                                 NowTransitionsStatus *out)
{
    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    out->cursor = cursor;
    out->now_ticks = now_ticks;
    out->capacity = (unsigned long)kNowEventRingRecords;
    if (!now_event_block_usable(block)) {
        /* Not usable is a complete answer, and it is NOT the same as
           empty: `usable` is what the two faces render as a refusal
           rather than as a quiet machine. Everything else stays zero
           because nothing else has been read. */
        return;
    }
    out->usable = 1;
    out->format = block->format;
    out->arm_a5 = block->arm_a5;
    out->arm_expiry = block->arm_expiry;
    out->arm_commit = block->arm_commit;
    out->expired = now_transitions_expired(block->arm_expiry, now_ticks);
    out->passes = block->passes;
    out->write_cursor = block->write_cursor;
    out->dropped = block->dropped;
    out->last_ticks = block->last_ticks;
    out->reader_cursor = block->reader_cursor;
    out->pending = now_event_pending(block, cursor, &out->lost);
}

int now_transitions_expired(NowEventU32 expiry, NowEventU32 now_ticks)
{
    if (expiry == 0) {
        /* No deadline is not an unbounded arm - it is no arm at all, and
           `now_event_arm` refuses to commit one. Reporting it as expired
           is the fail-closed reading and matches what the resident does
           with it. */
        return 1;
    }
    /* The resident's own comparison, deliberately identical: unsigned, so
       a TickCount wrap (roughly every 828 days at 60 Hz) does not read as
       expired forever. Two halves of one rule that disagreed about when a
       request lapses would be the worst kind of drift here, because the
       symptom is a plane that quietly stops. */
    return (NowEventU32)(expiry - now_ticks) > 0x7FFFFFFFu ? 1 : 0;
}

int now_transitions_ttl(long asked, NowEventU32 *out)
{
    if (out == NULL) {
        return 0;
    }
    if (asked == 0) {
        *out = (NowEventU32)kNowTransitionsTtlDefault;
        return 1;
    }
    if (asked < kNowTransitionsTtlMin || asked > kNowTransitionsTtlMax) {
        return 0;
    }
    *out = (NowEventU32)asked;
    return 1;
}

NowEventU32 now_transitions_reader_advance(NowEventU32 stored,
                                           NowEventU32 next)
{
    /* `next` is ahead of (or level with) `stored` when the unsigned
       distance forward is in the near half of the range. Anything else is
       a caller re-reading history, and history does not move the mark. */
    if ((NowEventU32)(next - stored) <= 0x7FFFFFFFu) {
        return next;
    }
    return stored;
}

const char *now_transitions_parse_line(const char *args,
                                       char *op, long op_cap)
{
    long n = 0;

    if (op == NULL || op_cap <= 0) {
        return "";
    }
    op[0] = '\0';
    if (args == NULL) {
        strcpy(op, "status");
        return "";
    }
    while (*args == ' ' || *args == '\t') {
        ++args;
    }
    while (*args != '\0' && *args != ' ' && *args != '\t') {
        if (n < op_cap - 1) {
            op[n++] = *args;
        }
        ++args;
    }
    op[n] = '\0';
    if (n == 0) {
        /* An empty line is status, for the reason the wire's absent `op`
           is: status is the only subcommand that neither writes nor moves
           a record, and a default that armed something would be a plane
           armed by a typo. */
        strcpy(op, "status");
    }
    while (*args == ' ' || *args == '\t') {
        ++args;
    }
    return args;
}

const char *now_transitions_kind_name(NowEventU32 kind)
{
    switch (kind) {
    case kNowEventKindWindowList:
        return "windowList";
    case kNowEventKindFrontProcess:
        return "frontProcess";
    case kNowEventKindMenuList:
        return "menuList";
    case kNowEventKindHeartbeat:
        return "heartbeat";
    default:
        break;
    }
    return "unknown";
}
