/* Native test for the anchor oracle (src/peek/peek_oracle.c).
 *
 * The oracle exists to answer "which slot is this process's, and is it
 * safe to believe it" - and the reason it was written Toolbox-free is
 * this file: all five verdicts are reachable here, on the host, by
 * building tables by hand. On a Macintosh, Ambiguous needs a recycled
 * slot from a dead process whose partition was reused, which is not
 * something a test can arrange.
 *
 * Mutation check, each watched failing 2026-07-31:
 *   - return Ok instead of Ambiguous on the second survivor    -> 1 fail
 *   - drop the has_stack gate (trust stack_base on a V1 table) -> 1 fail
 *   - use now_peek_range_in_partition for the stack base       -> 7 fail,
 *     led by the top-of-partition case, which is the NORMAL one
 *   - swap the Mismatch and NotFound diagnoses                 -> 5 fail,
 *     in both directions
 *
 * The last one is worth its footnote. Mutating it the obvious way -
 * hardcoding NotFound - does not compile, because `rejected` then goes
 * unused and -Werror rejects it. A mutation that fails to BUILD proves
 * nothing about the test; it had to be rewritten as a swap that keeps
 * the variable live before it demonstrated anything.
 */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "peek_oracle.h"

/* The partition every test below matches against. Deliberately not
   page-round: an off-by-one in the bounds arithmetic that happens to
   align would pass against a rounder number. */
enum {
    kLoc = 0x00100000L,
    kSize = 0x00080000L,
    kTop = kLoc + kSize
};

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static void check_verdict(NowPeekAnchorVerdict got, NowPeekAnchorVerdict want,
                          const char *what)
{
    if (got != want) {
        fprintf(stderr, "FAIL: %s (got %s, want %s)\n", what,
                now_peek_anchor_verdict_name(got),
                now_peek_anchor_verdict_name(want));
        ++g_failures;
    }
}

static void table_init(NowPeekTable *t, NowPeekU16 format)
{
    memset(t, 0, sizeof *t);
    t->magic = (NowPeekU32)kNowPeekTableMagic;
    t->ext_major = kNowPeekExtMajor;
    t->length = (NowPeekU32)sizeof *t;
    t->caps = kNowPeekTableCapAnchors;
    t->anchor_format = format;
}

/* Fill a slot the way capture_anchor does, minus the write ordering
   (which is the extension's concern, and peek_table_test pins it). */
static void slot_set(NowPeekTable *t, int i, NowPeekU32 a5, NowPeekU32 wl,
                     NowPeekU32 sb, NowPeekU32 stamp)
{
    t->anchors[i].a5 = a5;
    t->anchors[i].window_list = wl;
    t->anchors[i].menu_list = wl + 0x10;
    t->anchors[i].stack_base = sb;
    t->anchors[i].stamp_ticks = stamp;
    if (t->anchor_count < (NowPeekU16)(i + 1)) {
        t->anchor_count = (NowPeekU16)(i + 1);
    }
}

static NowPeekAnchorVerdict match(const NowPeekTable *t,
                                  NowPeekAnchorMatch *m)
{
    return now_peek_anchor_match(t, kLoc, kSize, 1000, 0, m);
}

int main(void)
{
    NowPeekTable t;
    NowPeekAnchorMatch m;

    /* ---- NotFound: the ordinary resting state ---- */
    table_init(&t, kNowPeekAnchorFormatV2);
    check_verdict(match(&t, &m), kNowPeekAnchorNotFound,
                  "empty table finds nothing");
    check(m.slot == -1, "no match leaves slot -1");

    /* A slot whose A5 is in a DIFFERENT partition is simply not ours -
       not a mismatch. Mismatch is about the two roots disagreeing, not
       about other processes existing. */
    slot_set(&t, 0, 0x00900000L, 0x00901000L, 0x00980000L, 500);
    check_verdict(match(&t, &m), kNowPeekAnchorNotFound,
                  "another process's slot is not this one's mismatch");

    /* A never-captured slot (stamp 0) is skipped even with a plausible
       A5 - the stamp is the validity bit, not the A5. */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 3, kLoc + 0x400, kLoc + 0x800, kTop, 0);
    check_verdict(match(&t, &m), kNowPeekAnchorNotFound,
                  "stamp 0 slot is never a match");

    /* ---- Ok, and the top-of-partition stack base ---- */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 5, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    check_verdict(match(&t, &m), kNowPeekAnchorOk, "one clean slot matches");
    check(m.slot == 5, "the matching slot index is reported");
    check(m.window_list == (NowPeekU32)(kLoc + 0x800), "window list carried");
    check(m.menu_list == (NowPeekU32)(kLoc + 0x810), "menu list carried");
    check(m.stamp_ticks == 800 && m.age_ticks == 200, "age is now - stamp");

    /* The stack grows DOWN from the top of the partition, so loc+size
       exactly is the normal value, not an out-of-bounds one. Running it
       through the readability test (which requires addr+4 <= top) would
       reject every real process on the machine. */
    check(m.stack_base == (NowPeekU32)kTop,
          "a stack base AT the top of the partition is in bounds");

    /* ---- Stale: reported, not refused ---- */
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, 1000, 100, &m),
                  kNowPeekAnchorStale, "an aged match past the gate is stale");
    check(m.slot == 5 && m.window_list == (NowPeekU32)(kLoc + 0x800),
          "stale still carries the fields - it is a labelled Ok");
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, 1000, 300, &m),
                  kNowPeekAnchorOk, "inside the gate it is plain Ok");
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, 1000, 0, &m),
                  kNowPeekAnchorOk, "max_age 0 disables the gate entirely");

    /* TickCount wraps roughly every 2.2 years of uptime. Unsigned
       subtraction gives the true elapsed count across the wrap; signed
       or clamped arithmetic would report an age of ~4 billion ticks and
       mark a live app permanently stale. */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 0, kLoc + 0x400, kLoc + 0x800, kTop, 0xFFFFFFF0UL);
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, 0x00000010UL, 100,
                                        &m),
                  kNowPeekAnchorOk, "age survives a TickCount wrap");
    check(m.age_ticks == 32, "wrapped age is the true elapsed count");

    /* ---- Mismatch: the two roots disagree ---- */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 2, kLoc + 0x400, kLoc + 0x800, 0x00900000L, 800);
    check_verdict(match(&t, &m), kNowPeekAnchorMismatch,
                  "A5 in partition, stack base outside it");
    check(m.slot == -1 && m.window_list == 0,
          "a refused verdict leaves no half-match behind");

    /* Absence of a second root is not disagreement. On a V1 table the
       stack_base bytes are whatever the shorter struct left there, so
       the format word - never the value - decides whether to look. */
    t.anchor_format = kNowPeekAnchorFormatV1;
    check_verdict(match(&t, &m), kNowPeekAnchorOk,
                  "V1 cannot detect a mismatch and must not invent one");

    /* ---- Ambiguous, and what V2 buys ---- */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 1, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    slot_set(&t, 7, kLoc + 0x500, kLoc + 0x900, kTop - 0x1000, 900);
    check_verdict(match(&t, &m), kNowPeekAnchorAmbiguous,
                  "two survivors are refused, not picked");
    check(m.slot == -1 && m.stamp_ticks == 0 && m.window_list == 0,
          "ambiguous fills nothing - there is no honest value");

    /* The point of carrying stack_base at all: the same two slots, with
       the ghost's stack base now outside the partition, resolve to the
       live one. Before V2 this pair was indistinguishable and the reader
       took whichever came first - which was sometimes the ghost. */
    t.anchors[7].stack_base = 0x00900000L;
    check_verdict(match(&t, &m), kNowPeekAnchorOk,
                  "a second root disambiguates what A5 alone could not");
    check(m.slot == 1, "and it resolves to the live slot, not the ghost");

    /* A ghost found FIRST must not win by position either. */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 0, kLoc + 0x500, kLoc + 0x900, 0x00900000L, 900);
    slot_set(&t, 4, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    check_verdict(match(&t, &m), kNowPeekAnchorOk,
                  "a leading ghost does not shadow a later clean slot");
    check(m.slot == 4, "the clean slot wins regardless of order");

    /* ---- Degenerate inputs fail closed ---- */
    check_verdict(now_peek_anchor_match(NULL, kLoc, kSize, 1000, 0, &m),
                  kNowPeekAnchorNotFound, "no table finds nothing");
    check_verdict(now_peek_anchor_match(&t, kLoc, 0, 1000, 0, &m),
                  kNowPeekAnchorNotFound, "a zero-size partition matches "
                                          "nothing");
    check_verdict(now_peek_anchor_match(&t, 0xFFFFF000UL, 0x00010000UL, 1000,
                                        0, &m),
                  kNowPeekAnchorNotFound, "a partition that wraps the address "
                                          "space matches nothing");

    /* The names are a rendered surface; a missing case would print an
       empty badge rather than fail a build. */
    check(strcmp(now_peek_anchor_verdict_name(kNowPeekAnchorOk), "ok") == 0
              && strcmp(now_peek_anchor_verdict_name(kNowPeekAnchorAmbiguous),
                        "ambiguous") == 0
              && strcmp(now_peek_anchor_verdict_name(kNowPeekAnchorMismatch),
                        "mismatch") == 0
              && strcmp(now_peek_anchor_verdict_name(kNowPeekAnchorStale),
                        "stale") == 0
              && strcmp(now_peek_anchor_verdict_name(kNowPeekAnchorNotFound),
                        "notFound") == 0,
          "every verdict has a name");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("peek_oracle: all checks passed\n");
    return EXIT_SUCCESS;
}
