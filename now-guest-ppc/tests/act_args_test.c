/*
 * act_args_test.c - the window act's argument grammar.
 *
 * The rule under test is small and it is the plane's rule in miniature:
 * an action takes exactly its own geometry keys, and a call carrying
 * anything else is a DIFFERENT request rather than a slightly-wrong one.
 * A close with a width is refused rather than performed with the width
 * discarded, because an act whose arguments cannot bound what it does is
 * the defect this whole design is shaped against.
 *
 * Mutations watched failing (2026-07-31), each reverted:
 *   - accept extra keys (drop the "!wants" half of each clause) -> a
 *     close carrying geometry is performed.
 *   - accept missing keys -> a move with no destination is performed.
 *   - extent floor 1 -> 0 -> a zero-width window is legal.
 *   - coordinate bound 32767 -> unbounded -> a destination no Rect can
 *     hold is accepted.
 */

#include "act_args.h"

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

static NowActWinArgs base(int action)
{
    NowActWinArgs a;

    memset(&a, 0, sizeof a);
    a.action = action;
    return a;
}

static int accepts(NowActWinArgs a)
{
    const char *reason = NULL;
    int         ok = now_act_win_args_check(&a, &reason);

    if (!ok && (reason == NULL || reason[0] == '\0')) {
        fprintf(stderr, "FAIL: a refusal with no reason\n");
        g_failures++;
    }
    return ok;
}

static void test_actions(void)
{
    check(now_act_win_action("move") == kNowActWinMove, "move");
    check(now_act_win_action("resize") == kNowActWinResize, "resize");
    check(now_act_win_action("zoom") == kNowActWinZoom, "zoom");
    check(now_act_win_action("close") == kNowActWinClose, "close");
    check(now_act_win_action("select") == kNowActWinSelect, "select");
    check(now_act_win_action("Move") == kNowActWinUnknown,
          "the vocabulary is exact, not case-folded");
    check(now_act_win_action("drag") == kNowActWinUnknown,
          "a word this plane does not know is unknown");
    check(now_act_win_action(NULL) == kNowActWinUnknown, "and so is nothing");

    check(now_act_zoom_direction("out") == 1, "zoom out");
    check(now_act_zoom_direction("in") == 0, "zoom in");
    check(now_act_zoom_direction("toggle") == -1,
          "there is no third zoom direction");
}

static void test_key_sets(void)
{
    NowActWinArgs a;

    a = base(kNowActWinMove);
    a.has_left = 1;
    a.has_top = 1;
    a.left = 40;
    a.top = 60;
    check(accepts(a), "move takes left and top");

    a.has_width = 1;
    a.width = 300;
    check(!accepts(a), "and refuses a size it has no meaning for");

    a = base(kNowActWinMove);
    a.has_left = 1;
    a.left = 40;
    check(!accepts(a), "half a destination is not a destination");

    a = base(kNowActWinResize);
    a.has_width = 1;
    a.has_height = 1;
    a.width = 420;
    a.height = 260;
    check(accepts(a), "resize takes width and height");

    a.has_top = 1;
    a.top = 10;
    check(!accepts(a), "and refuses an origin");

    /* zoom takes none: the standard state is the application's to
       compute, and a caller supplying one would be deciding what the
       window is for. close takes none and is destructive. */
    a = base(kNowActWinZoom);
    check(accepts(a), "zoom takes no geometry");
    a.has_width = 1;
    a.width = 300;
    check(!accepts(a), "zoom with a size is a different request");

    a = base(kNowActWinClose);
    check(accepts(a), "close takes no geometry");
    a.has_left = 1;
    a.left = 5;
    check(!accepts(a),
          "a close carrying geometry is refused, not performed and trimmed");

    a = base(kNowActWinSelect);
    check(accepts(a), "select takes no geometry");
    a.has_width = 1;
    a.width = 300;
    check(!accepts(a), "select carrying geometry is refused");

    a = base(kNowActWinUnknown);
    check(!accepts(a), "no action, no act");
}

static void test_bounds(void)
{
    NowActWinArgs a;

    a = base(kNowActWinMove);
    a.has_left = 1;
    a.has_top = 1;
    a.left = -32768L;
    a.top = 32767L;
    check(accepts(a), "the whole Rect range is legal for a destination");

    a.left = 32768L;
    check(!accepts(a), "one past it is not a place a window could be");
    a.left = -32769L;
    check(!accepts(a), "and neither is one before it");

    a = base(kNowActWinResize);
    a.has_width = 1;
    a.has_height = 1;
    a.width = 1;
    a.height = 1;
    check(accepts(a), "one point is the smallest expressible edge");
    a.width = 0;
    check(!accepts(a), "a zero-width window is refused here");
    a.width = -10;
    check(!accepts(a), "and so is a negative one");
    a.width = 32768L;
    check(!accepts(a), "an extent no Rect can hold is refused");

    check(!now_act_win_args_check(NULL, NULL), "no arguments, no act");
}

int main(void)
{
    test_actions();
    test_key_sets();
    test_bounds();

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("act_args: ok\n");
    return 0;
}
