/*
 * transitions_cmd.c - P5's four subcommands, and the only Toolbox in the
 * reader.
 *
 * Four things happen here that cannot happen in transitions_logic.c:
 * finding the block through the shared table, reading TickCount, holding
 * the plane's capability bit, and resolving a process to the target's
 * current validated A5. The host names a process; only the guest has the
 * anchor oracle that resolves it safely.
 *
 * WHAT THIS FILE DELIBERATELY DOES NOT DO, all four of them qdtrace's
 * (P3) and none of them P5's. Records here are fixed 24-byte structs, so
 * there is no size to distrust, no torn record and no resync. There is
 * one thing to record, so there is no mode. And there is no maxBytes,
 * because fixed width makes maxRecords bound the reply exactly.
 */

#include "transitions_cmd.h"

#include <Carbon.h>

#include "arm_target.h"
#include "json.h"
#include "peek.h"
#include "proc_actions.h"
#include "qdtrace_target.h"

#include <stddef.h>
#include <stdio.h>
#include <string.h>

/* ---- finding the block ----------------------------------------------
 *
 * Three gates, in the order an older resident fails them: the table must
 * be long enough to HAVE the appended word, the capability bit must say
 * the plane is published, and the address must be non-zero. Then
 * event_read.c's own acceptance rule checks magic, format and length.
 *
 * The system-range check mirror_probe.c performs is deliberately not
 * repeated here: that file reads the block from a probe that must survive
 * a hostile table, where this one is reached only after the same table
 * has already been validated by now_peek_table(). Duplicating it would
 * imply this path had a different threat model than it has.
 */
NowEventBlock *now_transitions_block(void)
{
    const NowPeekTable *t = now_peek_table();

    if (t == NULL) {
        return NULL;
    }
    /* The accretive rule that let the field be appended at all: a reader
       gates on `length` and never looks past what the writer claims. */
    if (t->length < (NowPeekU32)(offsetof(NowPeekTable, event_block)
                                 + sizeof(NowPeekU32))) {
        return NULL;
    }
    if ((t->caps & (NowPeekU32)kNowPeekTableCapEvents) == 0) {
        return NULL;               /* the extension carries P5 dark */
    }
    if (t->event_block == 0) {
        return NULL;
    }
    return (NowEventBlock *)(void *)(unsigned long)t->event_block;
}

void now_transitions_status(NowEventU32 cursor, NowTransitionsStatus *out)
{
    now_transitions_fill_status(now_transitions_block(), cursor,
                                (NowEventU32)TickCount(), out);
}

/* The resolved process's own name, for a reply that must say WHICH
   application it armed. A field read, not a decision - the matcher stays
   in proc_actions.c, once. Empty when the Process Manager will not answer,
   which is honest: the A5 beside it is still the resolved one. */
static void process_name_of(const ProcessSerialNumber *psn,
                            char *out, long cap)
{
    ProcessInfoRec info;
    Str31 name;

    if (out == NULL || cap <= 0) {
        return;
    }
    out[0] = '\0';
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    info.processName = name;
    info.processAppSpec = NULL;
    name[0] = 0;
    if (GetProcessInformation(psn, &info) != noErr) {
        return;
    }
    if (name[0] >= cap) {
        name[0] = (unsigned char)(cap - 1);
    }
    memcpy(out, name + 1, (size_t)name[0]);
    out[name[0]] = '\0';
}

int now_transitions_start(const NowTransitionsStartReq *req,
                          NowTransitionsArm *out,
                          const char **code, const char **message)
{
    NowEventBlock *block;
    NowQDTarget target;
    ProcessSerialNumber psn;
    unsigned long a5 = 0;
    NowEventU32 ttl = 0;
    NowEventU32 now_ticks;

    if (code != NULL) { *code = "unreadable"; }
    if (message != NULL) { *message = "this request cannot be served"; }
    if (req == NULL || out == NULL) {
        return 0;
    }
    memset(out, 0, sizeof *out);
    out->route = "none";

    block = now_transitions_block();
    if (block == NULL) {
        if (code != NULL) { *code = "transition-plane-absent"; }
        if (message != NULL) {
            *message = "the NOW Extension publishes no transition block: "
                       "not installed, or built without P5";
        }
        return 0;
    }
    if (!now_transitions_ttl(req->ttl_ticks, &ttl)) {
        if (code != NULL) { *code = "bad-ttl"; }
        if (message != NULL) {
            *message = "ttlTicks must be between 60 and 36000 "
                       "(60 ticks = 1 second)";
        }
        return 0;
    }

    /* THE NAME ROUTE IS THE CONSOLE'S, and it is resolved before the
       serial/front/a5 selector so a console line never has to invent one.
       A person at the machine has a name and no way to read a
       ProcessSerialNumber off this guest - nothing it prints carries
       one. */
    if (req->target != NULL && req->target[0] != '\0') {
        switch (now_proc_find_by_name(req->target, &psn)) {
        case kProcFindOne:
            break;
        case kProcFindNotRunning:
            if (code != NULL) { *code = "no-process"; }
            if (message != NULL) {
                *message = "nothing by that name is running (see \"ps\")";
            }
            return 0;
        case kProcFindAmbiguous:
            if (code != NULL) { *code = "ambiguous"; }
            if (message != NULL) {
                *message = "several processes have that name; this Mac "
                           "will not guess which one to instrument";
            }
            return 0;
        case kProcFindNoName:
        default:
            if (code != NULL) { *code = "no-target"; }
            if (message != NULL) { *message = "that names no process"; }
            return 0;
        }
        if (!now_peek_arm_target_a5(&psn, &a5, code, message)) {
            return 0;
        }
        out->route = "name";
        process_name_of(&psn, out->process, (long)sizeof out->process);
    } else {
        /* The wire's three routes, picked by the selector `qdtrace start`
           already uses - one implementation, because two selectors that
           disagreed would arm different processes for the same request. */
        target = now_qdtrace_pick_target(req->has_a5,
                                         req->has_serial_hi,
                                         req->has_serial_lo,
                                         req->has_front, req->front_true);
        /* Raw A5 is deliberately unnamed by the qdtrace route helper because
           P3 must refuse it. Transitions is the read-only application probe
           that still accepts an already-resolved address, so it owns that
           route name explicitly rather than reopening qdtrace's policy. */
        out->route = target == kNowQDTargetRawA5
            ? "a5" : now_qdtrace_target_route_name(target);
        switch (target) {
        case kNowQDTargetBadSerial:
            if (code != NULL) { *code = "bad-serial"; }
            if (message != NULL) {
                *message = "serialHi and serialLo must be sent together; "
                           "half a serial names a different process";
            }
            return 0;
        case kNowQDTargetNone:
            if (code != NULL) { *code = "no-target"; }
            if (message != NULL) {
                *message = "transitions start needs serialHi+serialLo, "
                           "front:true, a process name, or one "
                           "already-resolved a5; there is no arm-everything";
            }
            return 0;
        case kNowQDTargetSerial:
        case kNowQDTargetFront:
            if (target == kNowQDTargetFront) {
                if (GetFrontProcess(&psn) != noErr) {
                    if (code != NULL) { *code = "no-front"; }
                    if (message != NULL) {
                        *message = "there is no front process to arm";
                    }
                    return 0;
                }
            } else {
                psn.highLongOfPSN = (long)req->serial_hi;
                psn.lowLongOfPSN = (unsigned long)req->serial_lo;
            }
            if (!now_peek_arm_target_a5(&psn, &a5, code, message)) {
                return 0;
            }
            process_name_of(&psn, out->process, (long)sizeof out->process);
            break;
        case kNowQDTargetRawA5:
            a5 = (unsigned long)req->a5;
            break;
        }
    }

    if (a5 == 0) {
        /* Fail-closed, and stated rather than left to the resident: a
           zero target names NOTHING, never everything
           (docs/resident-components.md). now_event_arm refuses to commit
           one too, so this is the near end of one rule, not a second. */
        if (code != NULL) { *code = "no-target"; }
        if (message != NULL) {
            *message = "a zero A5 names no process; there is no "
                       "arm-everything";
        }
        return 0;
    }

    now_ticks = (NowEventU32)TickCount();
    out->a5 = (NowEventU32)a5;
    out->expiry = now_ticks + ttl;
    out->now_ticks = now_ticks;

    /* Two gates, and both are needed - qdtrace's order, for its reason:
       the table's capability bit says the plane may run at all, the block
       says on whom. Claiming the bit first means the resident can see an
       armed plane with no committed request, which is idle. The reverse
       is also idle, but only because nothing reads it yet; prefer the
       order that is idle for a stated reason. */
    now_peek_claim_until(kNowPeekOwnerEvents,
                         (unsigned long)kNowPeekTableCapEvents,
                         (unsigned long)out->expiry);
    now_event_arm(block, out->a5, out->expiry);
    return 1;
}

void now_transitions_stop(void)
{
    NowEventBlock *block = now_transitions_block();

    if (block != NULL) {
        now_event_disarm(block);
    }
    /* Released even when the block is gone: the lease is ours and an
       absent plane is no reason to keep asking for it. */
    now_peek_release(kNowPeekOwnerEvents,
                     (unsigned long)kNowPeekTableCapEvents);
}

unsigned long now_transitions_read(NowEventU32 cursor, NowEventRecord *out,
                                   unsigned long max, NowEventU32 *next,
                                   unsigned long *lost, int *usable)
{
    const NowEventBlock *block = now_transitions_block();

    if (usable != NULL) {
        *usable = now_event_block_usable(block);
    }
    return now_event_read(block, cursor, out, max, next, lost);
}

void now_transitions_commit_read(NowEventU32 next)
{
    NowEventBlock *block = now_transitions_block();

    if (!now_event_block_usable(block)) {
        return;
    }
    block->reader_cursor = now_transitions_reader_advance(
        block->reader_cursor, next);
}

/* ---- the wire face ---------------------------------------------------
 *
 * One renderer. The Console page renders the same facts as text in
 * console_model.c and decides nothing of its own.
 */

/* **A refusal must survive being parsed**, and this one did not. Measured
   on a live guest 2026-08-05: `transitions start` with no target refuses
   `no-process`, whose message reads `nothing by that name is running (see
   "ps")` — and those quotes went onto the wire unescaped, so every client
   got a JSON parse error at column 124 instead of the reason. The refusal
   was correct and unreadable, which is the worse half of the two.

   It is on an ERROR path, which is where a missing escape is least likely
   to be exercised and most likely to matter: a caller meeting it is
   already in trouble. `qdtrace_json.c` does this correctly and this file
   simply did not copy it — the same escaper, three lines away in the
   tree. Sibling verbs (`hide`, `quit`, `front`) carry the same
   quote-bearing sentence and DO escape it, confirmed live on the same
   machine. */
static void error_json(long id, const char *code, const char *message,
                       char *out, long cap)
{
    char esc[192];

    now_json_escape(message != NULL ? message : "", esc, (long)sizeof esc);
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":false,"
             "\"error\":{\"code\":\"%s\",\"message\":\"%s\"}}",
             id, code != NULL ? code : "error", esc);
}

static void run_status(const char *json, long id, char *out, long cap)
{
    NowTransitionsStatus st;
    unsigned long cursor = 0;
    int present = 0;

    if (!now_json_find_wide_u32(json, "cursor", &cursor, &present)) {
        error_json(id, "bad-cursor",
                   "cursor must be a decimal or 0x string", out, cap);
        return;
    }
    now_transitions_status((NowEventU32)cursor, &st);
    if (!st.usable) {
        error_json(id, "transition-plane-absent",
                   "the NOW Extension publishes no readable transition "
                   "block: not installed, built without P5, or a format "
                   "this build does not read", out, cap);
        return;
    }
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"transitions\":{\"cmd\":\"status\","
             "\"format\":%lu,"
             "\"request\":{\"a5\":\"0x%08lx\",\"expiry\":%lu,"
             "\"commit\":%lu,\"expired\":%s},"
             "\"activity\":{\"passes\":%lu,\"writeCursor\":%lu,"
             "\"dropped\":%lu,\"lastTicks\":%lu},"
             "\"ring\":{\"capacity\":%lu,\"pending\":%lu,\"lost\":%lu,"
             "\"readerCursor\":%lu},"
             "\"cursor\":%lu,\"now\":%lu}}}",
             id, (unsigned long)st.format,
             (unsigned long)st.arm_a5, (unsigned long)st.arm_expiry,
             (unsigned long)st.arm_commit, st.expired ? "true" : "false",
             (unsigned long)st.passes, (unsigned long)st.write_cursor,
             (unsigned long)st.dropped, (unsigned long)st.last_ticks,
             st.capacity, st.pending, st.lost,
             (unsigned long)st.reader_cursor,
             (unsigned long)st.cursor, (unsigned long)st.now_ticks);
}

static void run_start(const char *json, long id, char *out, long cap)
{
    NowTransitionsStartReq req;
    NowTransitionsArm arm;
    const char *code = "unreadable";
    const char *message = "";
    NowTransitionsArgsResult parsed;
    char target[64];

    /* The grammar is in transitions_logic.c so a host compiler can reach
       it. It was inline here, under <Carbon.h>, when it shipped a target
       key that shadowed the envelope and armed nothing. */
    parsed = now_transitions_start_args(json, &req, target,
                                        (long)sizeof target);
    if (parsed != kNowTransitionsArgsOK) {
        error_json(id, now_transitions_args_code(parsed),
                   now_transitions_args_message(parsed), out, cap);
        return;
    }

    if (!now_transitions_start(&req, &arm, &code, &message)) {
        error_json(id, code, message, out, cap);
        return;
    }
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"transitions\":{\"cmd\":\"start\","
             "\"a5\":\"0x%08lx\",\"resolvedVia\":\"%s\","
             "\"process\":\"%.31s\",\"expiry\":%lu,\"now\":%lu,"
             "\"requested\":true,\"armed\":false}}}",
             id, (unsigned long)arm.a5, arm.route, arm.process,
             (unsigned long)arm.expiry, (unsigned long)arm.now_ticks);
    /* `requested: true, armed: false` is not pessimism. Nothing records
       until the extension's own pass runs INSIDE the target process and
       agrees; this reply claims a request was written and never that it
       was honoured. `transitions status` reports `activity.passes`, which
       is the extension's own word for whether it ran. */
}

static void run_stop(long id, char *out, long cap)
{
    now_transitions_stop();
    snprintf(out, (size_t)cap,
             "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
             "\"output\":{\"transitions\":{\"cmd\":\"stop\","
             "\"requested\":true}}}", id);
    /* Same claim discipline: the resident stops recording at its next
       pass in the target's own context. This says the request was
       withdrawn. */
}

enum {
    /* Records copied per drain. Bounded by the 3072-byte reply buffer
       divided by a record's widest JSON, with room for the tail — the
       reply says `more` rather than truncating, so this number costs a
       second call and never a lost record. */
    kNowTransitionsMaxDrain = 24,
    /* Held back from every record so the tail below always fits. */
    kNowTransitionsTailReserve = 224
};

static void run_drain(const char *json, long id, char *out, long cap)
{
    NowEventRecord records[kNowTransitionsMaxDrain];
    NowTransitionsStatus st;
    unsigned long cursor = 0;
    unsigned long lost = 0;
    unsigned long want = kNowTransitionsMaxDrain;
    unsigned long got;
    unsigned long i;
    long asked;
    long pos;
    int present = 0;
    int usable = 0;
    NowEventU32 next = 0;

    if (!now_json_find_wide_u32(json, "cursor", &cursor, &present)) {
        error_json(id, "bad-cursor",
                   "cursor must be a decimal or 0x string", out, cap);
        return;
    }
    asked = now_json_find_int(json, "maxRecords", 0);
    if (asked > 0 && (unsigned long)asked < want) {
        want = (unsigned long)asked;
    }

    got = now_transitions_read((NowEventU32)cursor, records, want,
                               &next, &lost, &usable);
    if (!usable) {
        error_json(id, "transition-plane-absent",
                   "the NOW Extension publishes no readable transition "
                   "block: not installed, built without P5, or a format "
                   "this build does not read", out, cap);
        return;
    }
    /* Read a second time for the accounting the tail carries. Cheap, and
       it is the same block the records came from - a status assembled
       from a different pass could report a pending count the records
       contradict. */
    now_transitions_status((NowEventU32)cursor, &st);

    pos = snprintf(out, (size_t)cap,
                   "{\"type\":\"command.result\",\"id\":%ld,\"ok\":true,"
                   "\"output\":{\"transitions\":{\"cmd\":\"drain\","
                   "\"records\":[", id);
    if (pos < 0 || pos >= cap) {
        error_json(id, "overflow", "no room for a drain reply", out, cap);
        return;
    }
    for (i = 0; i < got; ++i) {
        long room = cap - pos - kNowTransitionsTailReserve;
        long n;

        if (room <= 0) {
            break;
        }
        n = snprintf(out + pos, (size_t)room,
                     "%s{\"ticks\":%lu,\"seq\":%lu,\"kind\":%lu,"
                     "\"kindName\":\"%s\",\"a5\":\"0x%08lx\","
                     "\"value\":\"0x%08lx\",\"previous\":\"0x%08lx\"}",
                     i == 0 ? "" : ",",
                     (unsigned long)records[i].ticks,
                     (unsigned long)records[i].seq,
                     (unsigned long)records[i].kind,
                     now_transitions_kind_name(records[i].kind),
                     (unsigned long)records[i].a5,
                     (unsigned long)records[i].value,
                     (unsigned long)records[i].previous);
        if (n < 0 || n >= room) {
            /* The record did not fit. Retract it rather than ship half of
               one: a truncated record parses as far as it goes, which is
               the failure this whole reserve exists to prevent. */
            out[pos] = '\0';
            break;
        }
        pos += n;
    }
    /* The reader's own resume point, walked back by whatever the reply
       could not hold. Derived from its answer rather than recomputed,
       because the resume point after a wrap is NOT the caller's cursor
       plus a count and a second derivation of it here is a second thing
       to get wrong. */
    next = (NowEventU32)(next - (NowEventU32)(got - i));

    /* `count`, NOT `records`. This tail sat beside a `"records":[...]`
       array in the same object, so a conforming parser kept the last of
       the two and the array vanished: 2853 bytes of real records on the
       wire and nothing able to read them (measured live, 2026-08-05, on
       this plane's first ever drain). A duplicate key is legal JSON and
       silently lossy. `qdtrace` names its array `ops` and never met
       this; the same rule as the arg keys, in the reply direction. */
    snprintf(out + pos, (size_t)(cap - pos),
             "],\"cursor\":%lu,\"nextCursor\":%lu,\"count\":%lu,"
             "\"lost\":%lu,\"dropped\":%lu,\"pending\":%lu,"
             "\"writeCursor\":%lu,\"more\":%s}}}",
             cursor, (unsigned long)next, i, lost,
             (unsigned long)st.dropped, st.pending,
             (unsigned long)st.write_cursor,
             next != st.write_cursor ? "true" : "false");

    /* Advanced only now, after the reply is whole: a caller that read
       records and could not render them must not have lost them
       (event_read.h). Forward only — see transitions_logic.h. */
    now_transitions_commit_read(next);
}

void now_transitions_run(const char *request_json, long id,
                         char *out, long cap)
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
    error_json(id, "unknown-op",
               "transitions op must be status, start, stop or drain",
               out, cap);
}
