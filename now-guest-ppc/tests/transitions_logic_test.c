/*
 * P5's command-layer decisions, the half that needs no Toolbox.
 *
 * event_read_test.c already covers the ring; this covers what the
 * `transitions` verb decides ON TOP of it, and three of those are
 * genuinely load-bearing rather than arithmetic:
 *
 *   - a request whose deadline has passed still reads commit=1 in the
 *     block, because nothing clears it. A status that showed only that
 *     word would report a live request that records nothing, forever.
 *   - the shared reader cursor is a HIGH-WATER MARK. It is what the
 *     resident reads to decide whether a write costs a reader its view,
 *     so a caller replaying an old cursor must not rewind it - `dropped`
 *     would start counting drops for records nobody is waiting for.
 *   - an unfamiliar kind is named "unknown" rather than mapped onto a
 *     familiar one. The resident loads at boot from a separately built
 *     binary, so one newer than this application is a real case, and the
 *     failure mode of a decoder here is plausible output.
 */
#include <stdio.h>
#include <string.h>

#include "transitions_logic.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

static void form(NowEventBlock *block)
{
    memset(block, 0, sizeof *block);
    block->magic = (NowEventU32)kNowEventBlockMagic;
    block->format = kNowEventFormatV1;
    block->length = (NowEventU32)sizeof *block;
}

int main(void)
{
    static NowEventBlock block;
    NowTransitionsStatus st;
    NowEventU32 ttl = 0;
    char op[16];
    const char *rest;

    /* ---- status: an unusable block is a refusal, not an empty ring ---- */
    memset(&block, 0, sizeof block);
    now_transitions_fill_status(&block, 0, 1000, &st);
    check(st.usable == 0, "a zeroed block is not usable");
    check(st.capacity == (unsigned long)kNowEventRingRecords,
          "the ring's size is a fact about the build, known even then");
    now_transitions_fill_status(NULL, 0, 1000, &st);
    check(st.usable == 0, "no block at all is the same refusal");

    form(&block);
    now_transitions_fill_status(&block, 0, 1000, &st);
    check(st.usable == 1, "a formed block is usable");
    check(st.pending == 0 && st.lost == 0, "and empty");
    check(st.now_ticks == 1000, "the caller's clock is carried, not read");

    /* ---- the expiry, which is the honesty guard --------------------- */
    block.arm_a5 = 0x1000;
    block.arm_expiry = 2000;
    block.arm_commit = 1;
    now_transitions_fill_status(&block, 0, 1000, &st);
    check(st.arm_commit == 1 && st.expired == 0,
          "a request inside its deadline is live");
    /* The same block, one second past the deadline. NOTHING in shared
       memory changed - the resident does not clear the application's
       cells - so commit still reads 1 and only `expired` tells the
       truth. */
    now_transitions_fill_status(&block, 0, 2061, &st);
    check(st.arm_commit == 1, "the commit word is untouched by lapsing");
    check(st.expired == 1, "and the status says so anyway");

    check(now_transitions_expired(0, 1000) == 1,
          "no deadline is no arm, not an unbounded one");
    /* Unsigned, so a TickCount wrap does not read as expired forever:
       an expiry just past the wrap is still in the future for a now just
       before it. */
    check(now_transitions_expired(10, 0xFFFFFFF0UL) == 0,
          "a deadline across the tick wrap is still in the future");
    check(now_transitions_expired(0xFFFFFFF0UL, 10) == 1,
          "and one a wrap behind is past");

    /* ---- the ttl bounds -------------------------------------------- */
    check(now_transitions_ttl(0, &ttl) == 1
              && ttl == (NowEventU32)kNowTransitionsTtlDefault,
          "absent means the default");
    check(now_transitions_ttl(kNowTransitionsTtlMin, &ttl) == 1
              && ttl == (NowEventU32)kNowTransitionsTtlMin,
          "the floor is inclusive");
    check(now_transitions_ttl(kNowTransitionsTtlMax, &ttl) == 1
              && ttl == (NowEventU32)kNowTransitionsTtlMax,
          "the ceiling is inclusive");
    ttl = 12345;
    check(now_transitions_ttl(kNowTransitionsTtlMin - 1, &ttl) == 0
              && ttl == 12345,
          "too short is refused, not clamped - a silently shortened arm "
          "looks exactly like a plane that stopped");
    check(now_transitions_ttl(kNowTransitionsTtlMax + 1, &ttl) == 0
              && ttl == 12345,
          "too long is refused, not clamped");
    check(now_transitions_ttl(-1, &ttl) == 0, "negative is refused");

    /* ---- the high-water rule --------------------------------------- */
    check(now_transitions_reader_advance(10, 20) == 20,
          "a drain that got further moves the mark");
    check(now_transitions_reader_advance(20, 20) == 20,
          "a drain that got nowhere leaves it");
    check(now_transitions_reader_advance(20, 10) == 20,
          "a caller replaying an old cursor does NOT rewind the mark - "
          "the resident reads it to decide whether a write costs a reader "
          "its view, and rewinding it makes `dropped` a fiction");
    /* Across the 32-bit wrap: 5 is ahead of 0xFFFFFFF0 by 21, not behind
       it by four billion. The resident's cursor counts records ever
       written and does wrap. */
    check(now_transitions_reader_advance(0xFFFFFFF0UL, 5) == 5,
          "forward across the wrap is still forward");
    check(now_transitions_reader_advance(5, 0xFFFFFFF0UL) == 5,
          "and backward across it is still backward");

    /* ---- kind names ------------------------------------------------ */
    check(strcmp(now_transitions_kind_name(kNowEventKindWindowList),
                 "windowList") == 0, "windowList");
    check(strcmp(now_transitions_kind_name(kNowEventKindFrontProcess),
                 "frontProcess") == 0, "frontProcess");
    check(strcmp(now_transitions_kind_name(kNowEventKindMenuList),
                 "menuList") == 0, "menuList");
    check(strcmp(now_transitions_kind_name(kNowEventKindHeartbeat),
                 "heartbeat") == 0, "heartbeat");
    check(strcmp(now_transitions_kind_name(0), "unknown") == 0,
          "a kind of zero is unknown, not a default");
    check(strcmp(now_transitions_kind_name(99), "unknown") == 0,
          "a kind from a newer resident is unknown rather than renamed");

    /* ---- the console line's grammar -------------------------------- */
    rest = now_transitions_parse_line("", op, (long)sizeof op);
    check(strcmp(op, "status") == 0 && rest[0] == '\0',
          "an empty line is status - the only op that moves nothing");
    rest = now_transitions_parse_line(NULL, op, (long)sizeof op);
    check(strcmp(op, "status") == 0, "and so is no line at all");
    rest = now_transitions_parse_line("   ", op, (long)sizeof op);
    check(strcmp(op, "status") == 0, "and so is whitespace");
    rest = now_transitions_parse_line("stop", op, (long)sizeof op);
    check(strcmp(op, "stop") == 0 && rest[0] == '\0', "a bare op");
    rest = now_transitions_parse_line("  start  Finder", op,
                                      (long)sizeof op);
    check(strcmp(op, "start") == 0 && strcmp(rest, "Finder") == 0,
          "leading and separating spaces are skipped");
    /* The whole rest of the line, because process names have spaces in
       them - the same rule quit and front parse by. */
    rest = now_transitions_parse_line("start Adobe Photoshop 5.5", op,
                                      (long)sizeof op);
    check(strcmp(op, "start") == 0
              && strcmp(rest, "Adobe Photoshop 5.5") == 0,
          "a name with spaces arrives whole");
    /* An op longer than the buffer is truncated rather than overflowing,
       and truncation makes it an unknown op - which the caller refuses.
       That is the safe direction: it can never truncate INTO a real op,
       because no op is a prefix of another. */
    rest = now_transitions_parse_line("startstartstartstartstart x", op,
                                      (long)sizeof op);
    check(strlen(op) == sizeof op - 1, "an over-long op is bounded");
    check(strcmp(op, "start") != 0,
          "and does not truncate into a real op");

    if (failures == 0) {
        printf("transitions_logic_test ok\n");
    }
    return failures == 0 ? 0 : 1;
}
