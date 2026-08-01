/* Native test for the NOW Extension's table contract. Runs on the host:

       cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST \
          -I ../../contract peek_table_test.c \
          -o peek_table_test && ./peek_table_test

   The static asserts in the header do the layout work at compile time
   on every compiler that includes it; this runtime half checks the
   values a wire-style reader depends on (magic, selector, versioning
   gates) and exercises the accretive-read rule the way the application
   will. Mutation check: reorder any two table fields and the header's
   own asserts refuse to build - watched once, 2026-07-21.

   Watched again for V3, 2026-07-31, with the cross-compiler half of the
   claim this time:
     - insert the name field BEFORE stack_base -> the header's asserts
       stop the build in the retrocarbon PPC compiler AND the Retro68
       68K one, not merely in the host cc (the 68K guest does not
       include this header; the extension does)
     - the same shift with those asserts RELAXED -> 3 runtime checks
       here fail, which is what this file is for: a build failure proves
       the asserts work, not that the test does
     - narrow the name field to 30 bytes with the size assert left
       satisfiable -> 2 fail. Note WHY that still compiled: the compiler
       silently padded the slot back to 60. That is precisely the drift
       the header's layout rule forbids, and only the alignment check
       sees it. */

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

    /* V2 appended stack_base. The seqlock's stamp must NOT have moved:
       a V1 reader looks for it at 20, and a silent shift there pairs a
       fresh stamp with fields it does not cover.

       The static asserts in the header catch this at compile time in all
       three toolchains, which is the stronger gate. These are here for
       the case the asserts are ever relaxed - watched failing with them
       removed, and they named both halves. */
    check(offsetof(NowPeekAnchorSlot, stamp_ticks) == 20,
          "V2 left the seqlock stamp where V1 reads it");
    check(offsetof(NowPeekAnchorSlot, stack_base) == 24,
          "stack_base was appended, not inserted");
    /* V3 appended again, under the same rule: both offsets above are
       unchanged, and the new field starts after them. */
    check(offsetof(NowPeekAnchorSlot, cur_ap_name) == 28,
          "cur_ap_name was appended, not inserted");
    check(kNowPeekAnchorFormatV2 > kNowPeekAnchorFormatV1
              && kNowPeekAnchorFormatV3 > kNowPeekAnchorFormatV2,
          "anchor formats are ordered, so >= is a valid gate");

    /* The layout rule the header states once: no compiler inserts
       padding, which holds only while every offset stays 4-aligned. The
       name field is bytes, so it is the one field that could break it -
       a width of 30 would compile here and silently shift the next
       appended field on a compiler that aligns to 4. */
    check(kNowPeekAnchorNameSize % 4 == 0,
          "the name width keeps the slot 4-aligned for the NEXT append");
    check(sizeof(NowPeekAnchorSlot) % 4 == 0
              && sizeof(NowPeekAnchorSlot) == 60,
          "the V3 slot is 60 bytes with no padding");
    /* A whole Str31 fits: length byte plus 31 characters, so there is
       no truncation rule for the two sides to disagree about. */
    check(kNowPeekAnchorNameSize == 32, "a Str31 fits the name field whole");

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

    /* An empty slot is invalid however you look at it - and its name is
       an empty Pascal string, which is "the extension had none", not
       "this process is nameless". */
    check(t.anchors[0].psn_high == 0 && t.anchors[0].psn_low == 0
              && t.anchors[0].stamp_ticks == 0
              && t.anchors[0].cur_ap_name[0] == 0,
          "zeroed slot reads as absent");

    /* V2's act cell: key_code/key_char/key_mods and menugeom's three
       scalars are APPENDED after selftest_got, so a V1 reader (there is
       none left in this tree, but the rule is the same one every other
       plane follows) would have found every field it knew unmoved. */
    check(offsetof(NowPeekActCell, key_code)
              == offsetof(NowPeekActCell, selftest_got) + 4,
          "key fields were appended, not inserted");
    check(offsetof(NowPeekActCell, menu_item_count)
              == offsetof(NowPeekActCell, key_mods) + 4,
          "menugeom's scalars follow key's, in one block");
    /* V3 appended the click's posting context between menugeom's
       scalars and the union, by the same rule: click_not_a5 /
       click_pending / click_posted / click_passes / click_last_a5, and
       nothing before them moved. */
    check(offsetof(NowPeekActCell, click_not_a5)
              == offsetof(NowPeekActCell, menu_height) + 4,
          "the click's context was appended after menugeom's scalars");
    check(offsetof(NowPeekActCell, text_buf)
              == offsetof(NowPeekActCell, click_last_a5) + 4,
          "the union starts right after the click's context");

    /* THE UNION IS THE WHOLE POINT of capping menugeom at 32 items: it
       must not grow the cell past what the text ops already need.
       MUTATION WATCHED FAILING (revert after use): widen
       kNowPeekActMenuItemMax to 40 (320 bytes) and this line catches it
       before the header's own static assert would have refused the
       build outright - this is what that assert reads like as a runtime
       check, the same belt-and-suspenders the anchor slot's tests use. */
    check(sizeof(((NowPeekActCell *)0)->menu_item_rects) == kNowPeekActTextMax,
          "menugeom's rects union with text_buf rather than growing the cell");
    check(kNowPeekActMenuItemMax * sizeof(NowPeekActMenuRect)
              == kNowPeekActTextMax,
          "the item cap is exactly what the union's width allows");
    check(sizeof(NowPeekActMenuRect) == 8,
          "a menu rect is four 16-bit fields - a QuickDraw Rect, field for "
          "field");

    /* A resident predating V3 reports V2 (or V1), and the plane's gate
       (now_act_guard.c, tested in now_act_guard_test.c) refuses it
       outright - this file only pins that the constants stay distinct
       and ordered so that gate means what it says. */
    check(kNowPeekActFormatV3 != kNowPeekActFormatV2
              && kNowPeekActFormatV3 > kNowPeekActFormatNone,
          "V2 is a distinct, nonzero format from V1");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("peek_table: all checks passed\n");
    return EXIT_SUCCESS;
}
