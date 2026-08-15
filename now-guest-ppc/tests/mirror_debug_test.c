/* Native (host-side) test for now-guest-ppc/src/mirror/mirror_debug.c.

   The mirror debug gate decides whether the diagnostic firehose reaches
   the log at all, so its two failure directions are both quiet: a parse
   that reads a typo as "on" floods every later log with a condition
   nobody chose, and a default that is not OFF makes the whole gate a
   no-op that ships looking finished. Both are asserted here, on the
   host cc, because the machine that runs this code is not the machine
   anyone iterates on. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "mirror_debug.h"

static void test_the_default_is_off(void)
{
    /* First question asked of a fresh process image: the tier must be
       opt-in, or the ring is 97% counters again with nobody having
       typed anything. */
    assert(now_mirror_debug_on() == 0);
}

static void test_parse_is_a_closed_grammar(void)
{
    assert(now_mirror_debug_parse("on") == kNowMirrorDebugOn);
    assert(now_mirror_debug_parse("off") == kNowMirrorDebugOff);

    /* Everything else is status — a typo must leave the machine in the
       condition the last call put it in, or a sweep quietly measures
       (and logs) the wrong one. */
    assert(now_mirror_debug_parse("") == kNowMirrorDebugStatus);
    assert(now_mirror_debug_parse(NULL) == kNowMirrorDebugStatus);
    assert(now_mirror_debug_parse("status") == kNowMirrorDebugStatus);
    assert(now_mirror_debug_parse("On") == kNowMirrorDebugStatus);
    assert(now_mirror_debug_parse("onn") == kNowMirrorDebugStatus);
    assert(now_mirror_debug_parse("o") == kNowMirrorDebugStatus);
    assert(now_mirror_debug_parse("of") == kNowMirrorDebugStatus);
    assert(now_mirror_debug_parse("1") == kNowMirrorDebugStatus);
}

static void test_set_and_read_round_trip(void)
{
    now_mirror_debug_set(1);
    assert(now_mirror_debug_on() == 1);
    now_mirror_debug_set(42);          /* any nonzero normalises to 1 */
    assert(now_mirror_debug_on() == 1);
    now_mirror_debug_set(0);
    assert(now_mirror_debug_on() == 0);
}

int main(void)
{
    test_the_default_is_off();
    test_parse_is_a_closed_grammar();
    test_set_and_read_round_trip();
    printf("mirror_debug_test: ok\n");
    return 0;
}
