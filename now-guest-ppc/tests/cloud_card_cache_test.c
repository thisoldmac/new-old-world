/* The Contacts card cache's pure half:
     cc -Wall -Wextra -Werror -I ../src -I ../src/cloud \
        cloud_card_cache_test.c ../src/cloud/cloud_card_cache.c \
        -o /tmp/t && /tmp/t

   Watched failing by mutation before trusting it: making slot_to_use
   always return slot 0 fails test_eviction_is_oldest_first (a middle
   entry vanishes instead of the true oldest); dropping the
   `!cache->entries[slot].used` guard around `++cache->count` in put()
   fails test_bounds_never_exceed_the_cap (count overruns the cap
   instead of holding steady once full); making cloud_card_cache_get
   refresh the entry's stamp (so a read counts as a "use") fails
   test_get_does_not_disturb_eviction_order (the repeatedly-read entry
   survives the overflow instead of the true oldest one being evicted). */

#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "cloud_card_cache.h"

static CloudCardRow one_row(const char *label, const char *value)
{
    CloudCardRow row;

    memset(&row, 0, sizeof row);
    strncpy(row.label, label, sizeof row.label - 1);
    strncpy(row.value, value, sizeof row.value - 1);
    return row;
}

static void test_miss_on_empty_cache(void)
{
    CloudCardCache cache;

    cloud_card_cache_reset(&cache);
    assert(cloud_card_cache_count(&cache) == 0);
    assert(cloud_card_cache_get(&cache, "c-1", NULL, NULL) == 0);
    /* NULL/empty item: never a hit, never a crash. */
    assert(cloud_card_cache_get(&cache, NULL, NULL, NULL) == 0);
    assert(cloud_card_cache_get(&cache, "", NULL, NULL) == 0);
}

static void test_put_get_roundtrip(void)
{
    CloudCardCache cache;
    CloudCardRow rows[2];
    CloudCardRow out[kCloudMaxCardRows];
    int count = -1;

    cloud_card_cache_reset(&cache);
    rows[0] = one_row("Name", "Ada Lovelace");
    rows[1] = one_row("work", "ada@example.com");
    cloud_card_cache_put(&cache, "c-3", rows, 2);

    assert(cloud_card_cache_count(&cache) == 1);
    assert(cloud_card_cache_get(&cache, "c-3", out, &count) == 1);
    assert(count == 2);
    assert(strcmp(out[0].label, "Name") == 0);
    assert(strcmp(out[1].value, "ada@example.com") == 0);

    /* A presence check needs neither out param. */
    assert(cloud_card_cache_get(&cache, "c-3", NULL, NULL) == 1);
    /* A different id: still a miss. */
    assert(cloud_card_cache_get(&cache, "c-4", NULL, NULL) == 0);
}

static void test_put_replaces_without_growing(void)
{
    CloudCardCache cache;
    CloudCardRow rows[1];
    int count = -1;

    cloud_card_cache_reset(&cache);
    rows[0] = one_row("Name", "First Answer");
    cloud_card_cache_put(&cache, "c-1", rows, 1);
    assert(cloud_card_cache_count(&cache) == 1);

    rows[0] = one_row("Name", "Second Answer");
    cloud_card_cache_put(&cache, "c-1", rows, 1);
    /* Same key: replaces in place, count unchanged. */
    assert(cloud_card_cache_count(&cache) == 1);

    {
        CloudCardRow out[kCloudMaxCardRows];

        assert(cloud_card_cache_get(&cache, "c-1", out, &count) == 1);
        assert(count == 1);
        assert(strcmp(out[0].value, "Second Answer") == 0);
    }
}

static void test_row_count_clamped_to_the_card_bound(void)
{
    CloudCardCache cache;
    CloudCardRow rows[kCloudMaxCardRows + 4];
    int i, count = -1;

    cloud_card_cache_reset(&cache);
    for (i = 0; i < kCloudMaxCardRows + 4; ++i) {
        char label[8];

        snprintf(label, sizeof label, "L%d", i);
        rows[i] = one_row(label, "v");
    }
    /* An over-long row_count (a malformed or future-widened reply)
       clamps rather than overruns the fixed-size entry. */
    cloud_card_cache_put(&cache, "c-1", rows, kCloudMaxCardRows + 4);
    assert(cloud_card_cache_get(&cache, "c-1", NULL, &count) == 1);
    assert(count == kCloudMaxCardRows);

    /* A negative row_count (a parse that found nothing) reads as
       zero, not as undefined. */
    cloud_card_cache_put(&cache, "c-2", rows, -1);
    assert(cloud_card_cache_get(&cache, "c-2", NULL, &count) == 1);
    assert(count == 0);
}

static void test_put_ignores_empty_or_null_item(void)
{
    CloudCardCache cache;
    CloudCardRow rows[1];

    cloud_card_cache_reset(&cache);
    rows[0] = one_row("Name", "Nobody");
    cloud_card_cache_put(&cache, "", rows, 1);
    cloud_card_cache_put(&cache, NULL, rows, 1);
    assert(cloud_card_cache_count(&cache) == 0);
}

static void fill_id(char *out, long cap, int i)
{
    snprintf(out, (size_t)cap, "c-%d", i);
}

static void test_bounds_never_exceed_the_cap(void)
{
    CloudCardCache cache;
    CloudCardRow rows[1];
    int i;

    cloud_card_cache_reset(&cache);
    rows[0] = one_row("Name", "x");
    for (i = 0; i < kCloudCardCacheCap * 2; ++i) {
        char id[16];

        fill_id(id, sizeof id, i);
        cloud_card_cache_put(&cache, id, rows, 1);
        assert(cloud_card_cache_count(&cache) <= kCloudCardCacheCap);
    }
    assert(cloud_card_cache_count(&cache) == kCloudCardCacheCap);
}

static void test_eviction_is_oldest_first(void)
{
    CloudCardCache cache;
    CloudCardRow rows[1];
    int i;
    char id[16];

    cloud_card_cache_reset(&cache);
    rows[0] = one_row("Name", "x");
    for (i = 0; i < kCloudCardCacheCap; ++i) {
        fill_id(id, sizeof id, i);
        cloud_card_cache_put(&cache, id, rows, 1);
    }
    assert(cloud_card_cache_count(&cache) == kCloudCardCacheCap);

    /* One more distinct item must evict entry 0 (the oldest stamp),
       never a middle one — the difference between LRU-by-insertion
       and "evict whatever slot_to_use happens to land on first". */
    fill_id(id, sizeof id, kCloudCardCacheCap);
    cloud_card_cache_put(&cache, id, rows, 1);
    assert(cloud_card_cache_count(&cache) == kCloudCardCacheCap);

    fill_id(id, sizeof id, 0);
    assert(cloud_card_cache_get(&cache, id, NULL, NULL) == 0);

    fill_id(id, sizeof id, kCloudCardCacheCap / 2);
    assert(cloud_card_cache_get(&cache, id, NULL, NULL) == 1);

    fill_id(id, sizeof id, kCloudCardCacheCap - 1);
    assert(cloud_card_cache_get(&cache, id, NULL, NULL) == 1);

    fill_id(id, sizeof id, kCloudCardCacheCap);
    assert(cloud_card_cache_get(&cache, id, NULL, NULL) == 1);
}

static void test_get_does_not_disturb_eviction_order(void)
{
    CloudCardCache cache;
    CloudCardRow rows[1];
    int i, n;
    char id[16];

    cloud_card_cache_reset(&cache);
    rows[0] = one_row("Name", "x");
    for (i = 0; i < kCloudCardCacheCap; ++i) {
        fill_id(id, sizeof id, i);
        cloud_card_cache_put(&cache, id, rows, 1);
    }

    /* Reading entry 0 many times (the prefetch's own "have I got this
       already" scan does exactly this every idle pass) must NOT save
       it from eviction — get() is a pure lookup. */
    fill_id(id, sizeof id, 0);
    for (n = 0; n < 5; ++n) {
        assert(cloud_card_cache_get(&cache, id, NULL, NULL) == 1);
    }

    fill_id(id, sizeof id, kCloudCardCacheCap);
    cloud_card_cache_put(&cache, id, rows, 1);

    fill_id(id, sizeof id, 0);
    assert(cloud_card_cache_get(&cache, id, NULL, NULL) == 0);
}

static void test_reset_clears_everything(void)
{
    CloudCardCache cache;
    CloudCardRow rows[1];

    cloud_card_cache_reset(&cache);
    rows[0] = one_row("Name", "x");
    cloud_card_cache_put(&cache, "c-1", rows, 1);
    assert(cloud_card_cache_count(&cache) == 1);

    cloud_card_cache_reset(&cache);
    assert(cloud_card_cache_count(&cache) == 0);
    assert(cloud_card_cache_get(&cache, "c-1", NULL, NULL) == 0);
}

int main(void)
{
    test_miss_on_empty_cache();
    test_put_get_roundtrip();
    test_put_replaces_without_growing();
    test_row_count_clamped_to_the_card_bound();
    test_put_ignores_empty_or_null_item();
    test_bounds_never_exceed_the_cap();
    test_eviction_is_oldest_first();
    test_get_does_not_disturb_eviction_order();
    test_reset_clears_everything();
    printf("cloud_card_cache_test: all assertions passed\n");
    return 0;
}
