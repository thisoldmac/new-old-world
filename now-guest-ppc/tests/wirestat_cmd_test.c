/* Native (host-side) test for now-guest-ppc/src/core/wirestat_cmd.c.

   `wirestat` is the instrument the whole wire-latency argument rests on,
   and it SETS the two things under test. A grammar that reads
   `wirestat sleep 3` as `sleep 0` does not fail - it applies a real,
   different setting, and every number taken afterwards is a measurement
   of a condition nobody chose. That is the failure this file exists for,
   and it is not hypothetical: now_cmd_arg_word answers a console line's
   FIRST word whatever key it is asked for, so the obvious implementation
   returns "sleep" for both `action` and `value`. */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "wirestat_cmd.h"

static void test_split_takes_two_distinct_words(void)
{
    char a[24], v[24];

    now_wirestat_split("sleep 3", a, sizeof a, v, sizeof v);
    assert(strcmp(a, "sleep") == 0);
    assert(strcmp(v, "3") == 0);       /* not "sleep" */

    now_wirestat_split("  wake   off  ", a, sizeof a, v, sizeof v);
    assert(strcmp(a, "wake") == 0);
    assert(strcmp(v, "off") == 0);

    now_wirestat_split("reset", a, sizeof a, v, sizeof v);
    assert(strcmp(a, "reset") == 0);
    assert(v[0] == '\0');

    now_wirestat_split("", a, sizeof a, v, sizeof v);
    assert(a[0] == '\0' && v[0] == '\0');
    now_wirestat_split(NULL, a, sizeof a, v, sizeof v);
    assert(a[0] == '\0' && v[0] == '\0');
}

static void test_an_overlong_word_does_not_become_two(void)
{
    char a[6], v[24];

    /* The tail of a word that did not fit must be skipped, not handed
       back as the next word - otherwise `sleeeeeeep 3` sets the sleep to
       whatever "eep" parses as. */
    now_wirestat_split("sleeeeeeep 3", a, sizeof a, v, sizeof v);
    assert(strcmp(a, "sleee") == 0);
    assert(strcmp(v, "3") == 0);
}

static void test_parse_maps_words_to_knobs(void)
{
    WireStatRequest r;

    now_wirestat_parse("sleep", "3", &r);
    assert(r.set_sleep && r.sleep_ticks == 3);
    assert(!r.set_wake && !r.reset);

    now_wirestat_parse("wake", "off", &r);
    assert(r.set_wake && r.wake_on == 0);

    now_wirestat_parse("wake", "on", &r);
    assert(r.set_wake && r.wake_on == 1);

    /* Bare `wake` does the harmless thing. */
    now_wirestat_parse("wake", "", &r);
    assert(r.set_wake && r.wake_on == 1);

    now_wirestat_parse("reset", "", &r);
    assert(r.reset && !r.set_wake && !r.set_sleep);
}

static void test_a_bare_or_unknown_verb_changes_nothing(void)
{
    WireStatRequest r;

    /* Reporting must never be a side effect. A typo has to leave the
       machine in the condition the last run put it in, or a sweep
       silently measures the wrong one. */
    now_wirestat_parse("", "", &r);
    assert(!r.reset && !r.set_wake && !r.set_sleep);
    now_wirestat_parse("slep", "3", &r);
    assert(!r.reset && !r.set_wake && !r.set_sleep);
    now_wirestat_parse(NULL, NULL, &r);
    assert(!r.reset && !r.set_wake && !r.set_sleep);
}

int main(void)
{
    test_split_takes_two_distinct_words();
    test_an_overlong_word_does_not_become_two();
    test_parse_maps_words_to_knobs();
    test_a_bare_or_unknown_verb_changes_nothing();
    printf("wirestat_cmd_test: all assertions passed\n");
    return 0;
}
