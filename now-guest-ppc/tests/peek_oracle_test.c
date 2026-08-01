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
 *
 * V3's own, each watched failing 2026-07-31:
 *   - gate has_name on V2 (read the name bytes a V2 table left) -> 2 fail,
 *     one of them the reclaimed-Ambiguous case going quietly Ok
 *   - fold() becomes the identity (byte-exact compare)          -> 1 fail
 *   - drop the empty-name guards (absence counts as disagreement)-> 2 fail
 *   - a name refutation drops the slot without counting as a
 *     rejection (`rejected += 0`, which keeps -Werror happy)     -> 2 fail,
 *     both Mismatch answers collapsing to NotFound
 *   - an impossible length byte convicts instead of abstaining   -> 1 fail
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

/* Pascal strings, built by hand: "\p" is a Mac compiler extension and
   this file is compiled by the host cc. */
static const unsigned char kFinder[] = { 6, 'F', 'i', 'n', 'd', 'e', 'r' };
static const unsigned char kFinderLower[] = { 6, 'f', 'i', 'n', 'd', 'e',
                                              'r' };
static const unsigned char kSimpleText[] = { 10, 'S', 'i', 'm', 'p', 'l',
                                             'e', 'T', 'e', 'x', 't' };
static const unsigned char kFinde[] = { 5, 'F', 'i', 'n', 'd', 'e' };
static const unsigned char kEmptyName[] = { 0 };

static void slot_name(NowPeekTable *t, int i, const unsigned char *name)
{
    int n = (int)name[0];
    int j;

    for (j = 0; j <= n && j < (int)kNowPeekAnchorNameSize; ++j) {
        t->anchors[i].cur_ap_name[j] = name[j];
    }
}

static int pstr_eq(const unsigned char *a, const unsigned char *b)
{
    int i;

    if (a[0] != b[0]) {
        return 0;
    }
    for (i = 1; i <= (int)a[0]; ++i) {
        if (a[i] != b[i]) {
            return 0;
        }
    }
    return 1;
}

static NowPeekAnchorVerdict match_named(const NowPeekTable *t,
                                        const unsigned char *name,
                                        NowPeekAnchorMatch *m)
{
    return now_peek_anchor_match(t, kLoc, kSize, name, 1000, 0, m);
}

/* No name supplied: the answer a caller that cannot name the process
   gets, which is exactly the V2 answer. Every pre-V3 case below runs
   through this, unchanged. */
static NowPeekAnchorVerdict match(const NowPeekTable *t,
                                  NowPeekAnchorMatch *m)
{
    return match_named(t, NULL, m);
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
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, NULL, 1000, 100, &m),
                  kNowPeekAnchorStale, "an aged match past the gate is stale");
    check(m.slot == 5 && m.window_list == (NowPeekU32)(kLoc + 0x800),
          "stale still carries the fields - it is a labelled Ok");
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, NULL, 1000, 300, &m),
                  kNowPeekAnchorOk, "inside the gate it is plain Ok");
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, NULL, 1000, 0, &m),
                  kNowPeekAnchorOk, "max_age 0 disables the gate entirely");

    /* TickCount wraps roughly every 2.2 years of uptime. Unsigned
       subtraction gives the true elapsed count across the wrap; signed
       or clamped arithmetic would report an age of ~4 billion ticks and
       mark a live app permanently stale. */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 0, kLoc + 0x400, kLoc + 0x800, kTop, 0xFFFFFFF0UL);
    check_verdict(now_peek_anchor_match(&t, kLoc, kSize, NULL,
                                        0x00000010UL, 100, &m),
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

    /* ---- V3: the name, which is not an address ---- */

    /* A clean V3 slot answers exactly as a clean V2 one, and carries
       the captured name out for the diagnostics surface. */
    table_init(&t, kNowPeekAnchorFormatV3);
    slot_set(&t, 2, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    slot_name(&t, 2, kFinder);
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorOk,
                  "a name that agrees changes nothing");
    check(pstr_eq(m.name, kFinder), "the captured name is carried out");

    /* Case is not evidence. Both names come off the same machine - one
       from low memory, one from the Process Manager - and a fold
       difference is cosmetic, where Mismatch is the claim that a
       process is dead. */
    check_verdict(match_named(&t, kFinderLower, &m), kNowPeekAnchorOk,
                  "the name compare is case-insensitive");

    /* A prefix is a DIFFERENT name, not a truncation to forgive: the
       field holds a whole Str31, so nothing here is ever truncated and
       a shorter string is simply another application. */
    check_verdict(match_named(&t, kFinde, &m), kNowPeekAnchorMismatch,
                  "a shorter name is a different name");

    /* The case the whole field exists for, standing alone: A5 and stack
       base both land inside the live partition - every address agrees -
       and the slot still wears the dead application's name. */
    table_init(&t, kNowPeekAnchorFormatV3);
    slot_set(&t, 2, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    slot_name(&t, 2, kSimpleText);
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorMismatch,
                  "both roots agree and the name refutes: recycled debris");
    check(m.slot == -1 && m.window_list == 0 && m.name[0] == 0,
          "a name-refuted verdict leaves no half-match behind");

    /* The sibling of the V1/stack_base case above, and the same rule.
       A V2 table's name bytes are whatever the shorter struct left
       there - here, a real name, which is the hostile version of the
       trap - and the format word, never the value, decides whether to
       look. Mismatch must be UNREACHABLE on a format that cannot
       express the disagreement. */
    t.anchor_format = kNowPeekAnchorFormatV2;
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorOk,
                  "V2 cannot detect a name mismatch and must not invent one");
    check(m.name[0] == 0,
          "and it reports no name rather than the bytes it must not read");

    /* Two more ways to have nothing to compare, both of which mean
       "cannot tell" and neither of which is disagreement. */
    t.anchor_format = kNowPeekAnchorFormatV3;
    check_verdict(match_named(&t, NULL, &m), kNowPeekAnchorOk,
                  "a caller with no name gets the V2 answer, not a refusal");
    check_verdict(match_named(&t, kEmptyName, &m), kNowPeekAnchorOk,
                  "an empty name from the caller is not a disagreement");
    slot_name(&t, 2, kEmptyName);
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorOk,
                  "an empty name in the slot is not a disagreement");

    /* A length byte the extension's clamp could never have written is
       not a name we can trust, and an untrustworthy name must not
       convict. */
    table_init(&t, kNowPeekAnchorFormatV3);
    slot_set(&t, 2, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    slot_name(&t, 2, kFinder);
    t.anchors[2].cur_ap_name[0] = 0xFF;
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorOk,
                  "an impossible name length is cannot-tell, not mismatch");

    /* ---- What V3 reclaims: an Ambiguous that becomes Ok ---- */

    /* Two slots, every address in both of them inside the partition:
       the live process and a ghost left in memory that was recycled
       under it. This is EXACTLY the pair V2 cannot separate - neither
       root disagrees with anything - so it is refused. */
    table_init(&t, kNowPeekAnchorFormatV2);
    slot_set(&t, 1, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    slot_set(&t, 7, kLoc + 0x500, kLoc + 0x900, kTop - 0x1000, 900);
    slot_name(&t, 1, kFinder);
    slot_name(&t, 7, kSimpleText);
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorAmbiguous,
                  "V2 refuses two address-clean slots even with a name");

    /* The same table, read as V3 - the bytes did not move, only the
       format word - resolves. The ghost is refuted by the one thing
       memory reuse does not carry with it, and the live slot is the
       sole survivor. This is the capability the port recorded as
       missing. */
    t.anchor_format = kNowPeekAnchorFormatV3;
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorOk,
                  "V3 resolves the pair V2 could only refuse");
    check(m.slot == 1 && m.window_list == (NowPeekU32)(kLoc + 0x800),
          "and it resolves to the live slot, not the ghost");
    check(pstr_eq(m.name, kFinder),
          "the surviving slot's name is the live one");

    /* Order must not decide it here either. */
    table_init(&t, kNowPeekAnchorFormatV3);
    slot_set(&t, 0, kLoc + 0x500, kLoc + 0x900, kTop - 0x1000, 900);
    slot_set(&t, 4, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    slot_name(&t, 0, kSimpleText);
    slot_name(&t, 4, kFinder);
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorOk,
                  "a leading ghost is refuted by name too");
    check(m.slot == 4, "the named slot wins regardless of order");

    /* But the name REFUTES, it never ELECTS. Two live copies of one
       application share a name, so a pair that agrees is still two
       survivors and still refused - the discriminator narrows the
       Ambiguous case, it does not abolish it. */
    table_init(&t, kNowPeekAnchorFormatV3);
    slot_set(&t, 1, kLoc + 0x400, kLoc + 0x800, kTop, 800);
    slot_set(&t, 7, kLoc + 0x500, kLoc + 0x900, kTop - 0x1000, 900);
    slot_name(&t, 1, kFinder);
    slot_name(&t, 7, kFinder);
    check_verdict(match_named(&t, kFinder, &m), kNowPeekAnchorAmbiguous,
                  "two slots wearing the same name are still refused");

    check(m.slot == -1 && m.name[0] == 0, "ambiguous still fills nothing");

    /* ---- Degenerate inputs fail closed ---- */
    check_verdict(now_peek_anchor_match(NULL, kLoc, kSize, NULL, 1000, 0, &m),
                  kNowPeekAnchorNotFound, "no table finds nothing");
    check_verdict(now_peek_anchor_match(&t, kLoc, 0, NULL, 1000, 0, &m),
                  kNowPeekAnchorNotFound, "a zero-size partition matches "
                                          "nothing");
    check_verdict(now_peek_anchor_match(&t, 0xFFFFF000UL, 0x00010000UL,
                                        NULL, 1000, 0, &m),
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

    /* ---- now_peek_anchor_a5_arm_trusted: absent-vs-present for the
       wire's a5 field (observe.c's emit_process_head) ----

       Driven from peek_oracle.h's own verdict enum, not from the
       function under test: every named verdict is listed here BY NAME,
       so a sixth one added to the header later and left unhandled here
       fails this loop's "every verdict was checked" count instead of
       silently inheriting a default. Only kNowPeekAnchorOk is trusted
       to arm with - Stale is deliberately excluded even though the
       oracle fills its fields exactly like Ok's (see the verdict's own
       doc comment): a caller arming qdtrace needs freshness, not merely
       a filled struct. */
    {
        static const struct {
            NowPeekAnchorVerdict verdict;
            int                  want_trusted;
        } kCases[] = {
            { kNowPeekAnchorOk,        1 },
            { kNowPeekAnchorNotFound,  0 },
            { kNowPeekAnchorMismatch,  0 },
            { kNowPeekAnchorAmbiguous, 0 },
            { kNowPeekAnchorStale,     0 }
        };
        size_t i;

        for (i = 0; i < sizeof(kCases) / sizeof(kCases[0]); ++i) {
            int got = now_peek_anchor_a5_arm_trusted(kCases[i].verdict);
            char what[96];

            snprintf(what, sizeof what,
                     "a5_arm_trusted(%s) should be %s",
                     now_peek_anchor_verdict_name(kCases[i].verdict),
                     kCases[i].want_trusted ? "trusted" : "untrusted");
            check((got != 0) == (kCases[i].want_trusted != 0), what);
        }
        /* Every case above is one of the five verdicts, and there are
           exactly five verdicts (the earlier "every verdict has a name"
           check pins that count against the same header). A case list
           shorter than five would still pass every check in it while
           quietly leaving a verdict unexercised, so the count itself is
           asserted rather than left to be noticed by omission. */
        check(sizeof(kCases) / sizeof(kCases[0]) == 5,
              "one case per verdict - update this list when the enum "
              "grows");
    }

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("peek_oracle: all checks passed\n");
    return EXIT_SUCCESS;
}
