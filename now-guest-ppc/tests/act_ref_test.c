/*
 * act_ref_test.c - opaque element references, and going stale.
 *
 * WHAT THIS PINS. The act plane's addressing is the reason it cannot
 * express "whatever is frontmost", which is the refusal upstream's
 * 18/20 measurement paid for. Two properties carry it: a reference is
 * only ever one this guest minted (so a caller cannot name an element it
 * never observed), and a reference whose element has MOVED is refused
 * rather than resolved to whatever now answers to the same title.
 *
 * The shape is the host's too - AgentIntegrationActPolicy validates the
 * same string with UUID(uuidString:) - so a mint this test accepts and
 * the host rejects would be a plane that works nowhere. Hence the
 * character-by-character check rather than a length check.
 *
 * Mutations watched failing (2026-07-31), each reverted:
 *   - mint with a fixed counter -> two mints collide.
 *   - accept uppercase hex -> a reference the host would refuse passes.
 *   - drop the fingerprint from still_matches -> a moved element
 *     resolves, which is the silent-wrong-target case.
 *   - format into a buffer one byte short instead of refusing -> a
 *     truncated reference that still parses.
 */

#include "act_ref.h"

#include <stdio.h>
#include <string.h>

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        g_failures++;
    }
}

static NowActRefTable g_table;

static NowActRefRow sample_window(void)
{
    NowActRefRow row;

    memset(&row, 0, sizeof row);
    row.kind = kNowActRefWindow;
    row.psn_hi = 0;
    row.psn_lo = 0x0012BC00UL;
    row.window_address = 0x00301000UL;
    row.fingerprint = 0xABCD1234UL;
    memcpy(row.title, "untitled", 8);
    row.title_len = 8;
    row.occurrence = 0;
    return row;
}

static void test_format(void)
{
    unsigned long words[4];
    char          buf[kNowActRefMax];
    int           i;

    words[0] = 0x01234567UL;
    words[1] = 0x89ABCDEFUL;
    words[2] = 0xFEDCBA98UL;
    words[3] = 0x76543210UL;

    check(now_act_ref_format(kNowActRefWindow, words, buf, (long)sizeof buf),
          "a window reference formats");
    check(strcmp(buf, "now-window-01234567-89ab-cdef-fedc-ba9876543210") == 0,
          "8-4-4-4-12, lowercase, in that order");

    check(now_act_ref_format(kNowActRefElement, words, buf, (long)sizeof buf),
          "an element reference formats");
    check(strncmp(buf, "now-element-", 12) == 0, "and carries its own prefix");

    /* Never a truncated reference: a half-written one that still parses
       is the single failure this format must not have. */
    check(!now_act_ref_format(kNowActRefWindow, words, buf, 20),
          "a buffer too small is refused, not truncated");
    check(!now_act_ref_format(99, words, buf, (long)sizeof buf),
          "an unknown kind mints nothing");

    /* Every one of the 16 hex digits has to survive the loop. */
    for (i = 0; i < 4; i++) {
        words[i] = 0xFFFFFFFFUL;
    }
    check(now_act_ref_format(kNowActRefWindow, words, buf, (long)sizeof buf),
          "all-ones formats");
    check(strcmp(buf, "now-window-ffffffff-ffff-ffff-ffff-ffffffffffff") == 0,
          "and is all f");
}

static void test_valid(void)
{
    check(now_act_ref_valid(kNowActRefWindow,
                            "now-window-01234567-89ab-cdef-fedc-ba9876543210"),
          "a well-formed window reference is valid");
    check(!now_act_ref_valid(kNowActRefElement,
                             "now-window-01234567-89ab-cdef-fedc-ba9876543210"),
          "a window reference is not an element reference");
    check(!now_act_ref_valid(kNowActRefWindow,
                             "now-window-01234567-89AB-cdef-fedc-ba9876543210"),
          "uppercase is refused - the host compares against lowercase");
    check(!now_act_ref_valid(kNowActRefWindow,
                             "now-window-0123456789abcdeffedcba9876543210"),
          "the dashes are part of the shape");
    check(!now_act_ref_valid(kNowActRefWindow,
                             "now-window-01234567-89ab-cdef-fedc-ba987654321g"),
          "a non-hex digit is refused");
    check(!now_act_ref_valid(kNowActRefWindow, "untitled"),
          "a title is not a reference - this plane has no such form");
    check(!now_act_ref_valid(kNowActRefWindow, ""), "nor is nothing");
    check(!now_act_ref_valid(kNowActRefWindow, NULL), "nor is NULL");
}

static void test_remember_and_find(void)
{
    NowActRefRow        row = sample_window();
    const NowActRefRow *found;
    NowActRefRow       *a;
    NowActRefRow       *b;
    char                first[kNowActRefMax];

    now_act_ref_reset(&g_table);
    a = now_act_ref_remember(&g_table, &row, 1000UL);
    check(a != NULL, "a row is remembered");
    check(now_act_ref_valid(kNowActRefWindow, a->ref),
          "and its minted reference is well formed");
    strcpy(first, a->ref);

    /* Two mints of the SAME element must differ: minting is an
       observation, and two observations are two references. */
    b = now_act_ref_remember(&g_table, &row, 1000UL);
    check(b != NULL && strcmp(b->ref, first) != 0,
          "a second mint of the same element is a different reference");

    found = now_act_ref_find(&g_table, first);
    check(found != NULL, "the first reference still resolves");
    check(found != NULL && found->window_address == 0x00301000UL,
          "and carries the address it was minted against");
    check(now_act_ref_find(&g_table,
                           "now-window-00000000-0000-0000-0000-000000000000")
              == NULL,
          "a reference this guest never minted resolves to nothing");
    check(now_act_ref_find(&g_table, "") == NULL, "and neither does nothing");

    /* The table is bounded, and a recycled reference reads as absent -
       the same answer a closed window gets. Both are true. */
    {
        int i;

        for (i = 0; i < kNowActRefSlots + 2; i++) {
            (void)now_act_ref_remember(&g_table, &row, (unsigned long)i);
        }
        check(now_act_ref_find(&g_table, first) == NULL,
              "a recycled reference is gone, not silently re-pointed");
    }
}

static void test_still_matches(void)
{
    NowActRefRow row = sample_window();

    row.control_handle = 0x00405000UL;

    check(now_act_ref_still_matches(&row, 0x00301000UL, 0x00405000UL,
                                    0xABCD1234UL),
          "an unmoved element still matches");
    check(!now_act_ref_still_matches(&row, 0x00302000UL, 0x00405000UL,
                                     0xABCD1234UL),
          "a different window address does not");
    check(!now_act_ref_still_matches(&row, 0x00301000UL, 0x00406000UL,
                                     0xABCD1234UL),
          "a different control handle does not");
    /* THE CASE THE OTHER TWO CANNOT CATCH: the addresses agree because
       the memory was reused, and only the fingerprint says so. */
    check(!now_act_ref_still_matches(&row, 0x00301000UL, 0x00405000UL,
                                     0x99999999UL),
          "a changed fingerprint refuses - a moved element is not this one");
    check(!now_act_ref_still_matches(NULL, 0, 0, 0), "no row matches nothing");
}

int main(void)
{
    test_format();
    test_valid();
    test_remember_and_find();
    test_still_matches();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("act_ref: ok\n");
    return 0;
}
