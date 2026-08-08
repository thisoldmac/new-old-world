/*
 * qdtrace_cmd.c - the four subcommands, and the only Toolbox in the
 * reader.
 *
 * Four things happen here that cannot happen in the other two files:
 * finding the block through the shared table, reading TickCount, setting
 * the plane's capability bit, and resolving a ProcessSerialNumber to the
 * target's current validated A5. The host names a process; only the guest
 * has the anchor oracle needed to resolve it safely.
 *
 * REGISTRATION IS NOT OURS. src/commands/commands.c is held by another
 * lane while this is written, so this file exposes now_qdtrace_run and
 * stops. The exact row it needs is stated in qdtrace.h's companion note
 * and in this thread's report; it is one #include, one dispatch arm, and
 * one help row.
 */

#include "qdtrace.h"

#include <Carbon.h>

#include "arm_target.h"
#include "json.h"
#include "mirror_policy.h"
#include "peek.h"
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
 * The wide-form parsers moved to json.c on 2026-08-05, when P5's
 * `transitions` needed the same three-way answer for the same reason
 * (json.h states it). These two are the local narrowing to a
 * NowContentU32, and nothing else.
 */
static int parse_u32(const char *json, const char *key,
                     NowContentU32 *out, int *present)
{
    unsigned long v = 0;

    if (!now_json_find_wide_u32(json, key, &v, present)) {
        return 0;
    }
    if (*present) {
        *out = (NowContentU32)v;
    }
    return 1;
}

static int parse_bool(const char *json, const char *key, int *out,
                      int *present)
{
    return now_json_find_wide_bool(json, key, out, present);
}

/* Resolve the selected live process exactly as observation does: bind its
   anchor, then apply the stricter trust gate required for arming. A stale
   anchor may still be useful to look at and is not safe to instrument.
 *
 * The rule itself moved to src/peek/arm_target.c on 2026-08-05, when P5's
 * `transitions start` needed the same answer. Two copies of a safety rule
 * do not fail to build when they drift - they fail to agree. */
static int resolve_start_target(const ProcessSerialNumber *psn,
                                NowContentU32 *a5, const char **code,
                                const char **message)
{
    unsigned long resolved = 0;

    if (!now_peek_arm_target_a5(psn, &resolved, code, message)) {
        return 0;
    }
    *a5 = (NowContentU32)resolved;
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
    NowContentU32 window = 0;
    NowContentU32 generation;
    int has_a5 = 0;
    int has_serial_hi = 0;
    int has_serial_lo = 0;
    int has_window = 0;
    int has_front = 0;
    int front_true = 0;
    NowQDTarget target;
    const char *route;
    char mode[16];
    long ttl;
    int verdict;

    if (!now_mirror_policy_enabled(kMirrorPolicyContent)) {
        now_qdtrace_error_json(id, "content-policy-disabled",
                               "drawing-content tracing is disabled in "
                               "Mirror settings", out, cap);
        return;
    }
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
    if (!parse_u32(json, "serialHi", &serial_hi, &has_serial_hi)
            || !parse_u32(json, "serialLo", &serial_lo, &has_serial_lo)) {
        now_qdtrace_error_json(id, "bad-serial",
                               "serialHi and serialLo must be decimal or "
                               "0x strings", out, cap);
        return;
    }
    if (!parse_u32(json, "window", &window, &has_window)
        || !has_window || window == 0) {
        now_qdtrace_error_json(id, "no-window",
                               "qdtrace start needs the exact nonzero scene "
                               "window address; there is no all-windows arm",
                               out, cap);
        return;
    }
    if (!parse_bool(json, "front", &front_true, &has_front)) {
        now_qdtrace_error_json(id, "bad-front",
                               "front must be true or false", out, cap);
        return;
    }

    target = now_qdtrace_pick_target(has_a5, has_serial_hi, has_serial_lo,
                                     has_front, front_true);
    route = now_qdtrace_target_route_name(target);
    switch (target) {
    case kNowQDTargetBadSerial:
        now_qdtrace_error_json(id, "bad-serial",
                               "serialHi and serialLo must be sent together; "
                               "half a serial names a different process",
                               out, cap);
        return;
    case kNowQDTargetNone:
        now_qdtrace_error_json(id, "no-target",
                               "qdtrace start needs serialHi+serialLo, "
                               "front:true, or one already-resolved a5; "
                               "there is no arm-everything", out, cap);
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
            psn.highLongOfPSN = (long)serial_hi;
            psn.lowLongOfPSN = (unsigned long)serial_lo;
        }
        if (!resolve_start_target(&psn, &a5, &fail_code, &fail_message)) {
            now_qdtrace_error_json(id, fail_code, fail_message, out, cap);
            return;
        }
        serial_hi = (NowContentU32)psn.highLongOfPSN;
        serial_lo = (NowContentU32)psn.lowLongOfPSN;
        break;
    }
    case kNowQDTargetA5:
        break;
    }
    if (!now_json_find_string(json, "mode", mode, (long)sizeof mode)) {
        mode[0] = '\0';
    }
    ttl = now_json_find_int(json, "ttlTicks", 0);
    generation = block->arm_generation + 1u;
    if (generation == 0) {
        generation = 1;
    }

    verdict = now_qdtrace_arm_plan(mode, a5, window,
                                   serial_hi, serial_lo, generation, ttl,
                                   (NowContentU32)TickCount(), &plan);
    if (verdict == kNowQDArmNoTarget) {
        now_qdtrace_error_json(id, "no-target",
                               "qdtrace start resolved a zero target; there "
                               "is no arm-everything",
                               out, cap);
        return;
    }
    if (verdict == kNowQDArmBadMode) {
        now_qdtrace_error_json(id, "bad-mode",
                               "mode must be \"count\", \"record\" or "
                               "\"probe\"",
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
    now_peek_claim_until(kNowPeekOwnerContent,
                         (unsigned long)kNowPeekTableCapContent,
                         (unsigned long)plan.expiry);
    now_qdtrace_arm_commit(block, &plan);

    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"qdtrace\":{\"cmd\":\"start\",\"a5\":\"0x%08lx\","
             "\"window\":\"0x%08lx\",\"generation\":%lu,"
             "\"resolvedVia\":\"%s\","
             "\"mode\":\"%s\",\"expiry\":%lu,\"now\":%lu,"
             "\"redrawRequested\":false,\"redrawServiced\":false,"
             "\"requested\":true,\"armed\":false}}}",
             id, (unsigned long)plan.a5, (unsigned long)plan.window,
             (unsigned long)plan.generation, route,
             plan.mode == (NowContentU32)kNowContentModeProbe
                 ? "probe"
                 : (plan.mode == (NowContentU32)kNowContentModeRecord
                        ? "record" : "count"),
             (unsigned long)plan.expiry, (unsigned long)TickCount());
    /* `requested: true, armed: false` is not pessimism. Nothing is hooked
       until the extension's jGNE pass runs INSIDE the target process and
       agrees; this reply claims a request was written and never that it
       was honoured. `qdtrace status` reports `active.a5`, which is the
       extension's own word for what actually happened. */
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
    now_peek_release(kNowPeekOwnerContent,
                     (unsigned long)kNowPeekTableCapContent);

    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"qdtrace\":{\"cmd\":\"stop\",\"requested\":true}}}",
             id);
    /* Same claim discipline: the hooks come OUT in the target's own
       context, at its next jGNE pass. This says the request was
       withdrawn. */
}

void now_qdtrace_stop_for_policy(void)
{
    NowContentBlock *block = now_qdtrace_block();

    if (block != NULL) {
        now_qdtrace_disarm(block);
    }
    now_peek_release(kNowPeekOwnerContent,
                     (unsigned long)kNowPeekTableCapContent);
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
