/* Native test for the NOW Extension's table contract. Runs on the host:

       cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST \
          -I ../../contract peek_table_test.c \
          -o peek_table_test && ./peek_table_test

   The static asserts in the header do the layout work at compile time
   on every compiler that includes it; this runtime half checks the
   values a wire-style reader depends on (magic, selector, versioning
   gates) and exercises the accretive-read rule the way the application
   will. Mutation check: reorder any two table fields and the header's
   own asserts refuse to build - watched once, 2026-07-21. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "peek_table.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* The application's acceptance rule, as it will ship: magic, exact
   major, and a length that covers what the reader wants. */
static int table_usable(const NowPeekTable *t, size_t want_length)
{
    return t->magic == (NowPeekU32)kNowPeekTableMagic
        && t->ext_major == kNowPeekExtMajor && t->length >= want_length;
}

int main(void)
{
    NowPeekTable t;

    check(kNowPeekGestaltSelector == 0x4E576578L, "selector is 'NWex'");
    check(kNowPeekTableMagic == 0x4E577074L, "magic is 'NWpt'");
    check((kNowPeekTableCapAnchors & kNowPeekTableCapTree) == 0,
          "capability bits are distinct");

    memset(&t, 0, sizeof t);
    t.magic = (NowPeekU32)kNowPeekTableMagic;
    t.ext_major = kNowPeekExtMajor;

    /* A core-only M0 table: prelude published, no anchor plane. */
    t.length = offsetof(NowPeekTable, anchors);
    t.anchor_format = kNowPeekAnchorFormatNone;
    check(table_usable(&t, offsetof(NowPeekTable, anchors)),
          "M0 prelude is readable");
    check(!table_usable(&t, sizeof(NowPeekTable)),
          "anchor read is refused when length stops at the prelude");

    /* A newer minor with a longer table still reads (accretive)... */
    t.ext_minor = 9;
    t.length = sizeof(NowPeekTable);
    check(table_usable(&t, sizeof(NowPeekTable)),
          "longer newer table reads");

    /* ...but a different major never does. */
    t.ext_major = kNowPeekExtMajor + 1;
    check(!table_usable(&t, offsetof(NowPeekTable, anchors)),
          "major mismatch is refused");
    t.ext_major = kNowPeekExtMajor;
    t.magic = 0;
    check(!table_usable(&t, 4), "missing magic is refused");

    /* An empty slot is invalid however you look at it. */
    check(t.anchors[0].psn_high == 0 && t.anchors[0].psn_low == 0
              && t.anchors[0].stamp_ticks == 0,
          "zeroed slot reads as absent");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("peek_table: all checks passed\n");
    return EXIT_SUCCESS;
}
