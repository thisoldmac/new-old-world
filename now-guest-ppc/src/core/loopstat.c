#include "loopstat.h"

#include <string.h>

/* Doubling from half a millisecond. The top edge is 133 ms because the
   quantity that motivated this file - the wait before an idle guest
   notices a request - was measured at 115 ms, and a distribution whose
   last real bucket sits below the measurement would report every sample
   as an overflow. */
static const unsigned long k_edges[kLoopStatBuckets] = {
    500UL, 1000UL, 2000UL, 4000UL, 8000UL, 16000UL,
    33000UL, 66000UL, 133000UL, 0UL       /* 0 = open-ended */
};

unsigned long loopstat_edge_us(int bucket)
{
    if (bucket < 0 || bucket >= kLoopStatBuckets) {
        return 0;
    }
    return k_edges[bucket];
}

void loopstat_reset(LoopStat *s)
{
    if (s == NULL) {
        return;
    }
    memset(s, 0, sizeof *s);
    /* Not zero: zero is a legal sample and would win every comparison,
       so an unstarted min would read as a measurement. */
    s->min_us = 0xFFFFFFFFUL;
}

void loopstat_add(LoopStat *s, unsigned long us)
{
    int i;

    if (s == NULL) {
        return;
    }
    if (s->n == 0 && s->min_us != 0xFFFFFFFFUL) {
        loopstat_reset(s);            /* a struct that was never reset */
    }
    ++s->n;
    s->total_us += us;
    if (us < s->min_us) {
        s->min_us = us;
    }
    if (us > s->max_us) {
        s->max_us = us;
    }
    for (i = 0; i < kLoopStatBuckets - 1; ++i) {
        if (us < k_edges[i]) {
            ++s->buckets[i];
            return;
        }
    }
    ++s->buckets[kLoopStatBuckets - 1];
}

int loopstat_median_bucket(const LoopStat *s)
{
    long half;
    long seen = 0;
    int i;

    if (s == NULL || s->n <= 0) {
        return -1;
    }
    /* The bucket holding the (n+1)/2-th sample counted from the bottom -
       the lower median for an even count, which is the conservative
       choice when the buckets above are the expensive ones. */
    half = (s->n + 1) / 2;
    for (i = 0; i < kLoopStatBuckets; ++i) {
        seen += s->buckets[i];
        if (seen >= half) {
            return i;
        }
    }
    return kLoopStatBuckets - 1;
}

unsigned long loopstat_mean_us(const LoopStat *s)
{
    if (s == NULL || s->n <= 0) {
        return 0;
    }
    return s->total_us / (unsigned long)s->n;
}
