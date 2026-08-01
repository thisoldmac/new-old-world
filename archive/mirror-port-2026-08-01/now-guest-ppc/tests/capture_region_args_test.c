/* Native test for capture.region's argument/bounds/refusal logic. Runs on
   the host:

       cc -Wall -Wextra -Werror -I ../src/screenshots \
          capture_region_args_test.c \
          ../src/screenshots/capture_region_args.c \
          -o capture_region_args_test && ./capture_region_args_test

   This is the ONLY part of capture.region a host cc can exercise. The
   Toolbox half — capture_screen_rect's clamp-to-device and the actual
   CopyBits — needs a GDevice and cannot be built here; wire.c's
   serve_capture_region calls this parser first and only reaches the
   Toolbox call after it passes, so what is pinned here is everything
   that can refuse BEFORE a GWorld is ever allocated. Refusal shape and
   ordering past this point (busy transfer/stream/shot) live in wire.c's
   static globals and are read as source text instead — see
   capture_region_source_test.py beside this file. */

#include <stdio.h>
#include <string.h>

#include "capture_region_args.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

static CaptureRegionArgs ok_parse(long l, long t, long r, long b, long depth,
                                  const char *what)
{
    CaptureRegionArgs a;
    char msg[160];

    msg[0] = '\0';
    if (!now_capture_region_parse(l, t, r, b, depth, &a, msg, sizeof msg)) {
        fprintf(stderr, "FAIL: %s (refused: %s)\n", what, msg);
        ++g_failures;
        memset(&a, 0, sizeof a);
    }
    return a;
}

/* Refusal, with a NON-EMPTY reason: a refusal nobody can read is the
   same defect as no refusal at all. */
static void bad_parse(long l, long t, long r, long b, long depth,
                      const char *what)
{
    CaptureRegionArgs a;
    char msg[160];

    msg[0] = '\0';
    if (now_capture_region_parse(l, t, r, b, depth, &a, msg, sizeof msg)) {
        fprintf(stderr, "FAIL: %s (accepted %ld,%ld,%ld,%ld depth=%ld)\n",
                what, l, t, r, b, depth);
        ++g_failures;
        return;
    }
    if (msg[0] == '\0') {
        fprintf(stderr, "FAIL: %s (refused with no reason)\n", what);
        ++g_failures;
    }
}

int main(void)
{
    CaptureRegionArgs a;

    /* The ordinary case. */
    a = ok_parse(10, 20, 110, 220, 8, "an ordinary rect at depth 8 parses");
    check(a.left == 10 && a.top == 20 && a.right == 110 && a.bottom == 220,
          "rect kept verbatim - the screen clamp is capture_screen_rect's job, not this parser's");
    check(a.depth == 8, "depth kept");

    /* depth 0 means "no preference" and always passes - the caller
       applies its own default (prefs.shot_depth), exactly like
       capture.request and process.shot already do. */
    a = ok_parse(0, 0, 100, 100, 0, "depth 0 (no preference) parses");
    check(a.depth == 0, "depth 0 passed through for the caller to default");

    /* Every depth QuickDraw actually supports. */
    {
        long depths[] = { 1, 2, 4, 8, 16, 32 };
        size_t i;

        for (i = 0; i < sizeof depths / sizeof depths[0]; ++i) {
            char what[64];

            snprintf(what, sizeof what, "depth %ld is accepted", depths[i]);
            a = ok_parse(0, 0, 50, 50, depths[i], what);
            check(a.depth == depths[i], "depth kept verbatim");
        }
    }

    /* THE BOUNDARY: exactly kCaptureRegionMaxDim on a side is the last
       one that passes; one more on either axis refuses. Off-by-one here
       is exactly the shape of bug this test exists to catch before a
       GWorld allocation ever sees it. */
    a = ok_parse(0, 0, kCaptureRegionMaxDim, kCaptureRegionMaxDim, 8,
                "exactly the max dimension on both sides parses");
    check(a.right - a.left == kCaptureRegionMaxDim, "width at the ceiling");

    bad_parse(0, 0, kCaptureRegionMaxDim + 1, 100, 8,
             "one pixel over the width ceiling is refused");
    bad_parse(0, 0, 100, kCaptureRegionMaxDim + 1, 8,
             "one pixel over the height ceiling is refused");

    /* Shape refusals: empty and inverted rects. A negative-area rect is
       not "smaller than empty" - it is the same refusal, because both
       describe a capture with no pixels in it. */
    bad_parse(50, 50, 50, 100, 8, "a zero-width rect is refused");
    bad_parse(50, 50, 100, 50, 8, "a zero-height rect is refused");
    bad_parse(100, 100, 50, 200, 8, "an inverted (right < left) rect is refused");
    bad_parse(100, 100, 200, 50, 8, "an inverted (bottom < top) rect is refused");

    /* Depth refusals: QuickDraw has no such pixel size. */
    bad_parse(0, 0, 100, 100, 24, "depth 24 does not exist on this Toolbox");
    bad_parse(0, 0, 100, 100, 3, "depth 3 does not exist on this Toolbox");
    bad_parse(0, 0, 100, 100, -1, "a negative depth is refused");

    /* Global coordinates can be negative (a window can sit left of or
       above the main screen's origin in a multi-monitor arrangement) -
       only the SIZE is bounded, never the position. */
    a = ok_parse(-500, -300, -400, -200, 8,
                "negative global coordinates parse - only size is bounded");
    check(a.left == -500 && a.top == -300, "negative origin kept verbatim");

    if (g_failures > 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("ok\n");
    return 0;
}
