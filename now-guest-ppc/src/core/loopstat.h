#ifndef NOW_LOOPSTAT_H
#define NOW_LOOPSTAT_H

/* A distribution, not an average.

   Every latency claim this project has got wrong was got wrong by a
   single number: a mean launders the tail on a cooperatively scheduled
   Macintosh, where one blocked pass can be a hundred times the median
   and is exactly the case a person notices. So the guest keeps a
   histogram with fixed, published edges and reports the whole thing;
   whoever reads it can take a median, a p90 or nothing at all, and can
   see how many samples the answer rests on.

   Log-spaced edges in MICROSECONDS. The two quantities this exists for
   sit at opposite ends of it - a loop pass is tens of milliseconds, and
   an Open Transport notification arriving mid-pass is tens of
   microseconds - so linear buckets would put every sample of one of them
   in a single bin.

   Pure arithmetic on purpose: no Toolbox, no Carbon, so the host `cc`
   compiles it and `scripts/test-native` runs the counting rules here
   rather than on a Macintosh that cannot be asserted about. */

#define kLoopStatBuckets 10

typedef struct {
    long n;                     /* samples counted */
    unsigned long total_us;     /* sum, for a mean when one is wanted */
    unsigned long min_us;
    unsigned long max_us;
    long buckets[kLoopStatBuckets];
} LoopStat;

/* Upper edge of bucket i, exclusive, in microseconds; the last bucket is
   open-ended and reports 0. Published so a reader is never guessing what
   a column means. */
unsigned long loopstat_edge_us(int bucket);

void loopstat_reset(LoopStat *s);
void loopstat_add(LoopStat *s, unsigned long us);

/* The bucket the median falls in, or -1 with no samples. A range, never
   an interpolated number: this holds counts, not samples, and an
   interpolated median off log buckets would be a precision the data does
   not have. */
int loopstat_median_bucket(const LoopStat *s);

/* Mean, or 0 with no samples. */
unsigned long loopstat_mean_us(const LoopStat *s);

#endif
