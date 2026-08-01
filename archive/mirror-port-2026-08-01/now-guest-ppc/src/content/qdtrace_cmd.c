/*
 * qdtrace_cmd.c - the four subcommands, and the only Toolbox in the
 * reader.
 *
 * Four things happen here that cannot happen in the other two files:
 * finding the block through the shared table, reading TickCount, setting
 * the plane's capability bit, and - since `start` stopped taking a bare
 * A5 - resolving the wire's PSN or `front` to one. That resolution is
 * exactly `observe`'s own (now_ax_bind_process, gated the same way on
 * now_peek_anchor_a5_arm_trusted; see resolve_start_target below), which
 * is why it is done here rather than reinvented: this file already links
 * axprocess.c, and a second binder would be a second opinion about which
 * anchor slot belongs to a process. Everything else - the walk, the
 * verdicts, the JSON, the arm ordering, and now which SELECTOR a request
 * named (qdtrace_target.h) - is next door and is executed by a host cc.
 *
 * REGISTRATION IS NOT OURS. src/commands/commands.c is held by another
 * lane while this is written, so this file exposes now_qdtrace_run and
 * stops. The exact row it needs is stated in qdtrace.h's companion note
 * and in this thread's report; it is one #include, one dispatch arm, and
 * one help row.
 */

#include "qdtrace.h"

#include <Carbon.h>

#include "axprocess.h"
#include "json.h"
#include "peek.h"
#include "peek_oracle.h"
#include "qdtrace_target.h"

#include <stdio.h>
#include <string.h>

/* ---- finding the block ----------------------------------------------
 *
 * The extension allocates the P3 block in the system heap and publishes
 * its address in the shared table's appended `content_block` word. That
 * word does not exist yet: contract/peek_table.h is owned by another lane
 * and content_table.h states both additions it is owed - the capability
 * bit kNowPeekTableCapContent, and the appended address field.
 *
 * So this compiles both ways ON PURPOSE, and the "not yet" branch is a
 * refusal with a reason rather than a stub that returns something. The
 * flag is the one content_table.h already names for the pair, because the
 * two additions are described there as one change; if they are ever
 * landed separately, this file is where that shows up as a build error,
 * which is the right place for it to show up.
 */
#ifdef NOW_PEEK_TABLE_HAS_CAP_CONTENT
#define NOW_QDTRACE_TABLE_HAS_BLOCK 1
#endif

NowContentBlock *now_qdtrace_block(void)
{
#ifdef NOW_QDTRACE_TABLE_HAS_BLOCK
    const NowPeekTable *t = now_peek_table();

    if (t == NULL) {
        return NULL;
    }
    /* The accretive prefs-record rule, which is the whole reason the
       field could be appended: a reader gates on `length` and never
       looks past what the writer claims. */
    if (t->length < (NowPeekU32)(offsetof(NowPeekTable, content_block)
                                 + sizeof(NowPeekU32))) {
        return NULL;
    }
    if ((t->caps & (NowPeekU32)kNowPeekTableCapContent) == 0) {
        return NULL;   /* the extension carries P3 dark */
    }
    if (t->content_block == 0) {
        return NULL;
    }
    return (NowContentBlock *)(void *)(unsigned long)t->content_block;
#else
    return NULL;
#endif
}

/* ---- argument parsing ------------------------------------------------
 *
 * A5 worlds and ring cursors are both 32-bit quantities that routinely
 * have the top bit set, and `long` is 32 bits on the machine this runs
 * on. So neither may ride a signed JSON integer: an A5 of 0x80000000
 * arrives as a negative long, and a write_cursor does exceed 2^31 after
 * two gigabytes of records. Both are accepted as strings, decimal or
 * 0x-prefixed, with the signed integer form kept only as a fallback for
 * the small values a human types by hand.
 */
static int parse_u32(const char *json, const char *key,
                     NowContentU32 *out, int *present)
{
    char buf[24];
    const char *p;
    unsigned long v = 0;
    int digits = 0;
    int base = 10;

    *present = 0;
    if (now_json_find_string(json, key, buf, (long)sizeof buf)) {
        p = buf;
        while (*p == ' ') {
            p++;
        }
        if (p[0] == '0' && (p[1] == 'x' || p[1] == 'X')) {
            base = 16;
            p += 2;
        }
        for (; *p != '\0'; ++p) {
            int d;

            if (*p >= '0' && *p <= '9') {
                d = *p - '0';
            } else if (base == 16 && *p >= 'a' && *p <= 'f') {
                d = *p - 'a' + 10;
            } else if (base == 16 && *p >= 'A' && *p <= 'F') {
                d = *p - 'A' + 10;
            } else {
                return 0;   /* a malformed number is refused, not floored */
            }
            v = v * (unsigned long)base + (unsigned long)d;
            digits++;
            if (digits > 10) {
                return 0;
            }
        }
        if (digits == 0) {
            return 0;
        }
        *out = (NowContentU32)v;
        *present = 1;
        return 1;
    }
    if (now_json_value(json, key) != NULL) {
        long n = now_json_find_int(json, key, 0);

        if (n < 0) {
            return 0;
        }
        *out = (NowContentU32)n;
        *present = 1;
        return 1;
    }
    return 1;   /* absent is not malformed */
}

/* `front`'s value, tolerant of the same two shapes parse_u32 is: the
   host's generic command args cross the wire as `[String: String]`
   (MirrorContentJoin.swift issues `qdtrace start` this way), so a
   boolean sent as "front" arrives QUOTED - `"front":"true"` - not as
   a bare JSON literal. A quoted "true"/"false" is read the same as the
   literal; anything else present is malformed rather than silently
   read as false, because a typo in the one field that picks WHICH
   process gets armed deserves to be named. */
static int parse_bool(const char *json, const char *key, int *out,
                      int *present)
{
    char buf[8];

    *present = 0;
    if (now_json_find_string(json, key, buf, (long)sizeof buf)) {
        if (strcmp(buf, "true") == 0) {
            *out = 1;
        } else if (strcmp(buf, "false") == 0) {
            *out = 0;
        } else {
            return 0;
        }
        *present = 1;
        return 1;
    }
    if (now_json_value(json, key) != NULL) {
        *out = now_json_find_bool(json, key, 0);
        *present = 1;
        return 1;
    }
    return 1;   /* absent is not malformed */
}

/* ---- resolving `start`'s target to an A5 ------------------------------
 *
 * `now_qdtrace_pick_target` (qdtrace_target.h) already decided WHICH
 * selector a request named; this does the Toolbox work that decision
 * cannot: turning a PSN or `front` into a live process and asking the
 * anchor oracle for its A5, EXACTLY the pattern `observe`'s
 * emit_process_head follows (observe.c:370) - now_ax_bind_process for
 * the bind, now_peek_anchor_a5_arm_trusted for whether the verdict is
 * trustworthy enough to ARM with, not merely to display. A Stale anchor
 * passes the bind (verdict_status maps Stale to kNowPeekReadOk, same as
 * Ok) and fails the trust check below - which is the whole reason the
 * two are not the same question. */
static int resolve_start_target(const ProcessSerialNumber *psn,
                                NowContentU32 *a5, const char **code,
                                const char **message)
{
    NowAxContext ctx;
    NowPeekReadStatus status = now_ax_bind_process(psn, &ctx);

    switch (status) {
    case kNowPeekReadOk:
        break;
    case kNowPeekReadNoPlane:
        *code = "anchor-plane-absent";
        *message = "the NOW Extension's window-anchor plane is not armed, "
                   "so no process can be resolved to an A5 from here";
        return 0;
    case kNowPeekReadNoAnchor:
        *code = "not-pumped";
        *message = "this process has not pumped its event loop since "
                   "anchors were armed, so its A5 is not yet known - bring "
                   "it forward or observe it, then ask again";
        return 0;
    case kNowPeekReadAmbiguous:
        *code = "ambiguous";
        *message = "two or more anchor slots claim this process's memory "
                   "partition; this Mac cannot say which one is it, and "
                   "will not guess";
        return 0;
    case kNowPeekReadMismatch:
        *code = "mismatch";
        *message = "an anchor claims this process's partition but "
                   "disagrees with it elsewhere - the slot is debris from "
                   "a different process, not a match";
        return 0;
    case kNowPeekReadNoWindows:
    case kNowPeekReadStub:
    case kNowPeekReadUnreadable:
    default:
        *code = "unreadable";
        *message = "this process's anchor was found but its own pointers "
                   "do not validate; there is nothing safe to arm";
        return 0;
    }
    if (!now_peek_anchor_a5_arm_trusted(ctx.verdict)) {
        /* Ok got here; Stale did too, and this is where they part ways
           (see the function's own header comment and observe.c:365). */
        *code = "a5-stale";
        *message = "this process's anchor was captured too long ago to "
                   "arm tracing against safely - fine to OBSERVE, not to "
                   "ARM; bring it forward so it pumps again, then retry";
        return 0;
    }
    *a5 = (NowContentU32)ctx.a5;
    return 1;
}

/* ---- the subcommands ------------------------------------------------- */

static void run_status(const char *json, long id, char *out, long cap)
{
    NowContentBlock *block = now_qdtrace_block();
    NowQDStatus st;
    NowContentU32 cursor = 0;
    int present = 0;

    if (!parse_u32(json, "cursor", &cursor, &present)) {
        now_qdtrace_error_json(id, "bad-cursor",
                               "cursor must be a decimal or 0x string",
                               out, cap);
        return;
    }
    now_qdtrace_status(block, cursor, &st);
    now_qdtrace_status_json(&st, id, out, cap);
}

static void run_drain(const char *json, long id, char *out, long cap)
{
    NowContentBlock *block = now_qdtrace_block();
    NowContentU32 cursor = 0;
    NowContentU32 max_bytes = 0;
    NowContentU32 max_records = 0;
    int present = 0;
    long n;

    if (!parse_u32(json, "cursor", &cursor, &present)) {
        now_qdtrace_error_json(id, "bad-cursor",
                               "cursor must be a decimal or 0x string",
                               out, cap);
        return;
    }
    n = now_json_find_int(json, "maxBytes", 0);
    if (n > 0) {
        max_bytes = (NowContentU32)n;
    }
    n = now_json_find_int(json, "maxRecords", 0);
    if (n > 0) {
        max_records = (NowContentU32)n;
    }
    now_qdtrace_drain_json(block, cursor, max_bytes, max_records,
                           id, out, cap);
}

static void run_start(const char *json, long id, char *out, long cap)
{
    NowContentBlock *block = now_qdtrace_block();
    NowQDArmPlan plan;
    NowContentU32 a5 = 0;
    NowContentU32 serial_hi = 0;
    NowContentU32 serial_lo = 0;
    int has_a5 = 0;
    int has_serial_hi = 0;
    int has_serial_lo = 0;
    int has_front = 0;
    int front_true = 0;
    NowQDTarget target;
    const char *route;
    char mode[16];
    long ttl;
    int verdict;

    if (block == NULL) {
        now_qdtrace_error_json(id, "content-plane-absent",
                               "the NOW Extension publishes no content "
                               "block: not installed, or built without P3",
                               out, cap);
        return;
    }
    if (!parse_u32(json, "a5", &a5, &has_a5)) {
        now_qdtrace_error_json(id, "bad-a5",
                               "a5 must be a decimal or 0x string",
                               out, cap);
        return;
    }
    if (!parse_u32(json, "serialHi", &serial_hi, &has_serial_hi)) {
        now_qdtrace_error_json(id, "bad-serial",
                               "serialHi must be a decimal or 0x string",
                               out, cap);
        return;
    }
    if (!parse_u32(json, "serialLo", &serial_lo, &has_serial_lo)) {
        now_qdtrace_error_json(id, "bad-serial",
                               "serialLo must be a decimal or 0x string",
                               out, cap);
        return;
    }
    if (!parse_bool(json, "front", &front_true, &has_front)) {
        now_qdtrace_error_json(id, "bad-front",
                               "front must be true or false", out, cap);
        return;
    }

    /* WHICH selector, decided Toolbox-free and natively tested
       (qdtrace_target_test.c); RESOLVING it is everything below and is
       not. */
    target = now_qdtrace_pick_target(has_a5, has_serial_hi, has_serial_lo,
                                     has_front, front_true);
    route = now_qdtrace_target_route_name(target);

    switch (target) {
    case kNowQDTargetBadSerial:
        now_qdtrace_error_json(id, "bad-serial",
                               "serialHi and serialLo must be sent "
                               "together, or not at all - half a serial "
                               "names a different process, not none",
                               out, cap);
        return;
    case kNowQDTargetNone:
        /* The refusal this plane exists for. An arm with no target is
           read by the extension as "hook nothing"; a caller who meant
           "everything" is told no here, by name, rather than watching a
           request succeed and produce silence. */
        now_qdtrace_error_json(id, "no-target",
                               "qdtrace start needs a target: "
                               "serialHi+serialLo, front:true, or the a5 "
                               "of one already-resolved process; there is "
                               "no arm-everything",
                               out, cap);
        return;
    case kNowQDTargetSerial:
    case kNowQDTargetFront: {
        ProcessSerialNumber psn;
        const char *fail_code = "unreadable";
        const char *fail_message = "";

        if (target == kNowQDTargetFront) {
            if (GetFrontProcess(&psn) != noErr) {
                now_qdtrace_error_json(id, "no-front",
                                       "there is no front process to arm",
                                       out, cap);
                return;
            }
        } else {
            /* Same construction and the same casts observe.c's
               now_observe_elements_command uses for the identical pair
               (observe.c:770-771) - one spelling for "a PSN off the
               wire, in two halves". */
            psn.highLongOfPSN = (long)serial_hi;
            psn.lowLongOfPSN = (unsigned long)serial_lo;
        }
        if (!resolve_start_target(&psn, &a5, &fail_code, &fail_message)) {
            now_qdtrace_error_json(id, fail_code, fail_message, out, cap);
            return;
        }
        break;
    }
    case kNowQDTargetA5:
        break;          /* a5 already parsed above; nothing to resolve */
    }

    if (!now_json_find_string(json, "mode", mode, (long)sizeof mode)) {
        mode[0] = '\0';
    }
    ttl = now_json_find_int(json, "ttlTicks", 0);

    verdict = now_qdtrace_arm_plan(mode, a5, ttl,
                                   (NowContentU32)TickCount(), &plan);
    if (verdict == kNowQDArmNoTarget) {
        /* Reachable even after a target was named: the resolved a5 was
           the impossible-in-practice zero (peek_oracle.h's own
           qualifier on that value). Still refused, by the same rule. */
        now_qdtrace_error_json(id, "no-target",
                               "qdtrace start needs a target: "
                               "serialHi+serialLo, front:true, or the a5 "
                               "of one already-resolved process; there is "
                               "no arm-everything",
                               out, cap);
        return;
    }
    if (verdict == kNowQDArmBadMode) {
        now_qdtrace_error_json(id, "bad-mode",
                               "mode must be \"count\" or \"record\"",
                               out, cap);
        return;
    }
    if (verdict == kNowQDArmBadTtl) {
        char msg[128];

        snprintf(msg, sizeof msg,
                 "ttlTicks must be between %d and %d (60 ticks = 1 second)",
                 (int)kNowQDTtlMin, (int)kNowQDTtlMax);
        now_qdtrace_error_json(id, "bad-ttl", msg, out, cap);
        return;
    }

    /* Two gates, and both are needed: the table's capability bit says the
       plane may run at all, the block says on whom. Setting the bit
       before the block's cells means the extension can see an armed plane
       with no committed request, which is idle - the harmless order.
       The reverse would be a committed request the plane bit had not yet
       enabled, which is also idle, but only because nothing reads it
       yet. Prefer the order that is idle for a stated reason. */
    now_peek_arm((unsigned long)kNowPeekTableCapContent);
    now_qdtrace_arm_commit(block, &plan);

    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"qdtrace\":{\"cmd\":\"start\",\"a5\":\"0x%08lx\","
             "\"resolvedVia\":\"%s\","
             "\"mode\":\"%s\",\"expiry\":%lu,\"now\":%lu,"
             "\"requested\":true,\"armed\":false}}}",
             id, (unsigned long)plan.a5, route,
             plan.mode == (NowContentU32)kNowContentModeRecord
                 ? "record" : "count",
             (unsigned long)plan.expiry, (unsigned long)TickCount());
    /* `requested: true, armed: false` is not pessimism. Nothing is hooked
       until the extension's jGNE pass runs INSIDE the target process and
       agrees; this reply claims a request was written and never that it
       was honoured. `qdtrace status` reports `active.a5`, which is the
       extension's own word for what actually happened. `resolvedVia`
       names WHICH selector produced the a5 above - never which one the
       caller also sent, since only one resolves per now_qdtrace_pick_target. */
}

static void run_stop(long id, char *out, long cap)
{
    NowContentBlock *block = now_qdtrace_block();

    if (block == NULL) {
        now_qdtrace_error_json(id, "content-plane-absent",
                               "the NOW Extension publishes no content "
                               "block: not installed, or built without P3",
                               out, cap);
        return;
    }
    now_qdtrace_disarm(block);
    /* The plane bit is released too. Leaving it set would keep a dormant
       plane armed at the table level for no reason, and the counters that
       say "a request was refused" would keep ticking on nothing. */
    now_peek_disarm((unsigned long)kNowPeekTableCapContent);

    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"qdtrace\":{\"cmd\":\"stop\",\"requested\":true}}}",
             id);
    /* Same claim discipline: the hooks come OUT in the target's own
       context, at its next jGNE pass. This says the request was
       withdrawn. */
}

void now_qdtrace_run(const char *request_json, long id, char *out, long cap)
{
    char op[16];

    if (out == NULL || cap <= 0) {
        return;
    }
    if (request_json == NULL
        || !now_json_find_string(request_json, "op", op, (long)sizeof op)) {
        /* Status is the default because it is the only subcommand that
           neither writes nor moves a record. A default that armed
           something would be a plane armed by a typo. */
        strcpy(op, "status");
    }

    if (strcmp(op, "status") == 0) {
        run_status(request_json, id, out, cap);
        return;
    }
    if (strcmp(op, "drain") == 0) {
        run_drain(request_json, id, out, cap);
        return;
    }
    if (strcmp(op, "start") == 0) {
        run_start(request_json, id, out, cap);
        return;
    }
    if (strcmp(op, "stop") == 0) {
        run_stop(id, out, cap);
        return;
    }
    now_qdtrace_error_json(id, "unknown-op",
                           "qdtrace op must be status, start, stop or drain",
                           out, cap);
}
