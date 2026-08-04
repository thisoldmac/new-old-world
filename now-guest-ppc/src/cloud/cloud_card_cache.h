#ifndef NOW_CLOUD_CARD_CACHE_H
#define NOW_CLOUD_CARD_CACHE_H

#include "cloud_model.h"

/* The Contacts card cache: what makes "loaded when the list loads"
   true without a per-selection wire round trip. Filled by
   cloud_module.c's background prefetch (one cloud.detail ask in
   flight, ever, only while the wire is otherwise idle) and by every
   ordinary selection's own ask (a cache miss still asks the wire, and
   the answer is worth keeping). Toolbox-free on purpose, like
   cloud_model.h and cloud_filter.h — insert/lookup/evict/bounds is the
   half worth the host cc (cloud_card_cache_test.c), and it owes
   nothing to a Data Browser or a wire frame to be correct. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#else
typedef unsigned char Boolean;
#endif

enum {
    /* One entry per row a contacts listing can hold at once
       (kCloudMaxRows, 128 — cloud_model.h's own bound): the prefetch
       walks the LISTED rows exactly once and this page never shows
       more than kCloudMaxRows of them, so a cache sized to match can
       hold every card the prefetch will ever try to keep warm — no
       entry is evicted to make room for another row from the SAME
       list. One entry costs roughly sizeof(CloudCardCacheEntry):
       kCloudMaxCardRows (16) CloudCardRow rows at 152 bytes each
       (label[24] + value[128]) is 2432 bytes, plus a 64-byte item id
       and a little bookkeeping — about 2.5KB. 128 entries is
       therefore around 320KB, roughly 5% of the 6MB partition this
       guest runs in, well inside what the rest of the page already
       spends on a 128-row listing and a Data Browser. Eviction still
       exists and is tested below even though ordinary use never
       triggers it at this cap: correctness under "asked to hold more
       than it can" is a different claim than "never asked to", and
       the one this cache actually needs to keep is the second —
       cheap to prove now, expensive to discover missing later if a
       future caller (a second listable service, a tighter build)
       assumes it. */
    kCloudCardCacheCap = kCloudMaxRows
};

typedef struct {
    char item[64];
    CloudCardRow rows[kCloudMaxCardRows];
    int row_count;
    Boolean used;              /* false = empty slot */
    unsigned long stamp;       /* insertion order; lower = older */
} CloudCardCacheEntry;

typedef struct {
    CloudCardCacheEntry entries[kCloudCardCacheCap];
    int count;                 /* slots in use, always <= the cap */
    unsigned long clock;       /* next stamp handed to a put() */
} CloudCardCache;

void cloud_card_cache_reset(CloudCardCache *cache);

/* Inserts or replaces the entry for `item`. row_count is clamped to
   kCloudMaxCardRows defensively (every real caller already parsed
   through that cap, but this function's own correctness should not
   depend on that). When the cache is already at kCloudCardCacheCap
   and `item` is not already one of its entries, evicts the entry with
   the OLDEST stamp — the row this page asked about longest ago. A
   NULL or empty `item` is a no-op: there is nothing to key it by. */
void cloud_card_cache_put(CloudCardCache *cache, const char *item,
                          const CloudCardRow *rows, int row_count);

/* True (and, when rows_out/count_out are non-NULL, filled) for a hit;
   false (and both left untouched) for a miss or an empty/NULL item.
   A pure lookup — it does not disturb eviction order, so the
   prefetch's own "have I already got this one" scan (rows_out and
   count_out both NULL) costs nothing extra to call. rows_out, when
   given, must hold at least kCloudMaxCardRows entries. */
Boolean cloud_card_cache_get(const CloudCardCache *cache, const char *item,
                             CloudCardRow *rows_out, int *count_out);

/* Slots currently in use — never more than kCloudCardCacheCap. Exists
   for the bounds test below; nothing in the page needs to ask it. */
int cloud_card_cache_count(const CloudCardCache *cache);

#endif /* NOW_CLOUD_CARD_CACHE_H */
