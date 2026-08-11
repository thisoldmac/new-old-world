/* Native (host-side) test for now-guest-ppc/src/core/loopstat.c.

   The histogram is the instrument every wire-latency claim in
   docs/open-issues.md now rests on, and an instrument that miscounts
   does not fail - it reports a plausible wrong number, which is the
   worst failure mode available to a measurement. So the counting rules
   are asserted here, where a host compiler can run them, rather than
   inferred from a guest's own output.

   The three that would each have produced a believable lie:

   - a sample exactly ON a bucket edge counted into the bucket below,
     which shifts a whole distribution one bin left;
   - an unstarted `min_us` reading as 0, so every run reports a
     zero-microsecond best case it never saw;
   - a median taken as `n/2` rather than `(n+1)/2`, which lands in the
     wrong bucket for every odd-sized sample - and every hand run of the
     bench takes an odd number of samples about half the time. */

#include <assert.h>
#include <stdio.h>

#include "loopstat.h"

static void test_edges_are_exclusive_upper(void)
{
    LoopStat s;

    loopstat_reset(&s);
    /* 499 is under the first edge; 500 is NOT - the edge is the upper
       bound of bucket 0, exclusive. Off by one here moves every reading
       in the file down a bin. */
    loopstat_add(&s, 499);
    assert(s.buckets[0] == 1);
    loopstat_add(&s, 500);
    assert(s.buckets[0] == 1);
    assert(s.buckets[1] == 1);
    loopstat_add(&s, 999);
    assert(s.buckets[1] == 2);
    loopstat_add(&s, 1000);
    assert(s.buckets[2] == 1);
}

static void test_overflow_bucket_is_open_ended(void)
{
    LoopStat s;

    loopstat_reset(&s);
    assert(loopstat_edge_us(kLoopStatBuckets - 1) == 0);   /* published */
    loopstat_add(&s, 132999);
    assert(s.buckets[kLoopStatBuckets - 2] == 1);
    loopstat_add(&s, 133000);
    loopstat_add(&s, 4000000);
    assert(s.buckets[kLoopStatBuckets - 1] == 2);
}

static void test_min_is_not_zero_before_the_first_sample(void)
{
    LoopStat s;

    loopstat_reset(&s);
    assert(s.n == 0);
    assert(s.min_us == 0xFFFFFFFFUL);        /* not 0 */
    assert(loopstat_median_bucket(&s) == -1); /* and no median at all */
    assert(loopstat_mean_us(&s) == 0);
    loopstat_add(&s, 7000);
    assert(s.min_us == 7000);
    assert(s.max_us == 7000);
}

static void test_zero_is_a_legal_sample(void)
{
    LoopStat s;

    /* A pass that took less than a microsecond is a real reading, and on
       a machine with a wake that works it is the COMMON one. It must not
       be indistinguishable from "never measured". */
    loopstat_reset(&s);
    loopstat_add(&s, 0);
    assert(s.n == 1);
    assert(s.min_us == 0);
    assert(s.buckets[0] == 1);
}

static void test_median_bucket_is_the_lower_median(void)
{
    LoopStat s;
    int i;

    loopstat_reset(&s);
    /* Three cheap, two expensive: the median is cheap. n/2 = 2 would
       still land in bucket 0 here, so the odd case below is the one that
       separates the two rules. */
    for (i = 0; i < 3; ++i) {
        loopstat_add(&s, 100);
    }
    for (i = 0; i < 2; ++i) {
        loopstat_add(&s, 100000);
    }
    assert(loopstat_median_bucket(&s) == 0);

    /* THE CASE THAT SEPARATES THE TWO RULES, and the reason this test
       is written with counts chosen rather than sampled. One cheap, two
       expensive: the middle sample of three is expensive. `n/2` is 1,
       which the cheap bucket alone already satisfies, so that rule
       answers bucket 0 - a median an order of magnitude below the truth,
       reported with no sign of anything wrong. Every odd-sized run of
       the bench would carry it. */
    loopstat_reset(&s);
    loopstat_add(&s, 100);
    loopstat_add(&s, 100000);
    loopstat_add(&s, 100000);
    assert(loopstat_median_bucket(&s) == 8);

    /* The same trap one bucket wider: two cheap, three expensive. */
    loopstat_reset(&s);
    loopstat_add(&s, 100);
    loopstat_add(&s, 200);
    loopstat_add(&s, 100000);
    loopstat_add(&s, 100000);
    loopstat_add(&s, 100000);
    assert(loopstat_median_bucket(&s) == 8);

    /* One cheap, three expensive: the median has moved. */
    loopstat_reset(&s);
    loopstat_add(&s, 100);
    loopstat_add(&s, 100000);
    loopstat_add(&s, 100000);
    loopstat_add(&s, 100000);
    assert(loopstat_median_bucket(&s) == 8);
}

static void test_mean_and_totals(void)
{
    LoopStat s;

    loopstat_reset(&s);
    loopstat_add(&s, 1000);
    loopstat_add(&s, 3000);
    assert(s.total_us == 4000);
    assert(loopstat_mean_us(&s) == 2000);
    assert(s.min_us == 1000);
    assert(s.max_us == 3000);
}

static void test_null_is_survivable(void)
{
    /* Every caller here is on the wire's service path, where a crash is
       a dropped connection rather than an error message. */
    loopstat_reset(NULL);
    loopstat_add(NULL, 5);
    assert(loopstat_median_bucket(NULL) == -1);
    assert(loopstat_mean_us(NULL) == 0);
}

int main(void)
{
    test_edges_are_exclusive_upper();
    test_overflow_bucket_is_open_ended();
    test_min_is_not_zero_before_the_first_sample();
    test_zero_is_a_legal_sample();
    test_median_bucket_is_the_lower_median();
    test_mean_and_totals();
    test_null_is_survivable();
    printf("loopstat_test: all assertions passed\n");
    return 0;
}
