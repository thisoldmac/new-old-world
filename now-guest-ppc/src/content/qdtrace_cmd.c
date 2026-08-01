/*
 * qdtrace_cmd.c - the four subcommands, and the only Toolbox in the
 * reader.
 *
 * Three things happen here that cannot happen in the other two files:
 * finding the block through the shared table, reading TickCount, and
 * setting the plane's capability bit. Everything else - the walk, the
 * verdicts, the JSON, the arm ordering - is next door and is executed by
 * a host cc.
 *
 * REGISTRATION IS NOT OURS. src/commands/commands.c is held by another
 * lane while this is written, so this file exposes now_qdtrace_run and
 * stops. The exact row it needs is stated in qdtrace.h's companion note
 * and in this thread's report; it is one #include, one dispatch arm, and
 * one help row.
 */

#include "qdtrace.h"

#include <Carbon.h>

#include "json.h"
#include "peek.h"

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
    int present = 0;
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
    if (!parse_u32(json, "a5", &a5, &present)) {
        now_qdtrace_error_json(id, "bad-a5",
                               "a5 must be a decimal or 0x string",
                               out, cap);
        return;
    }
    if (!now_json_find_string(json, "mode", mode, (long)sizeof mode)) {
        mode[0] = '\0';
    }
    ttl = now_json_find_int(json, "ttlTicks", 0);

    verdict = now_qdtrace_arm_plan(mode, a5, ttl,
                                   (NowContentU32)TickCount(), &plan);
    if (verdict == kNowQDArmNoTarget) {
        /* The refusal this plane exists for. An arm with no target is
           read by the extension as "hook nothing"; a caller who meant
           "everything" is told no here, by name, rather than watching a
           request succeed and produce silence. */
        now_qdtrace_error_json(id, "no-target",
                               "qdtrace start needs the a5 of ONE process "
                               "to instrument; there is no arm-everything",
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
             "\"mode\":\"%s\",\"expiry\":%lu,\"now\":%lu,"
             "\"requested\":true,\"armed\":false}}}",
             id, (unsigned long)plan.a5,
             plan.mode == (NowContentU32)kNowContentModeRecord
                 ? "record" : "count",
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
