#include "cloud_card_cache.h"

#include <string.h>

void cloud_card_cache_reset(CloudCardCache *cache)
{
    memset(cache, 0, sizeof *cache);
}

static int find_slot(const CloudCardCache *cache, const char *item)
{
    int i;

    if (item == NULL || item[0] == '\0') {
        return -1;
    }
    for (i = 0; i < kCloudCardCacheCap; ++i) {
        if (cache->entries[i].used
            && strcmp(cache->entries[i].item, item) == 0) {
            return i;
        }
    }
    return -1;
}

/* An empty slot always wins over evicting a filled one; among filled
   slots, the one with the smallest stamp (asked about longest ago). */
static int slot_to_use(const CloudCardCache *cache)
{
    int i, oldest = 0;
    unsigned long oldest_stamp = 0;
    Boolean have_oldest = 0;

    for (i = 0; i < kCloudCardCacheCap; ++i) {
        if (!cache->entries[i].used) {
            return i;
        }
        if (!have_oldest || cache->entries[i].stamp < oldest_stamp) {
            oldest = i;
            oldest_stamp = cache->entries[i].stamp;
            have_oldest = 1;
        }
    }
    return oldest;
}

void cloud_card_cache_put(CloudCardCache *cache, const char *item,
                          const CloudCardRow *rows, int row_count)
{
    int slot;
    int n = row_count;

    if (item == NULL || item[0] == '\0') {
        return;
    }
    if (n < 0) {
        n = 0;
    }
    if (n > kCloudMaxCardRows) {
        n = kCloudMaxCardRows;
    }
    slot = find_slot(cache, item);
    if (slot < 0) {
        slot = slot_to_use(cache);
        if (!cache->entries[slot].used) {
            ++cache->count;
        }
    }
    memset(&cache->entries[slot], 0, sizeof cache->entries[slot]);
    strncpy(cache->entries[slot].item, item,
           sizeof cache->entries[slot].item - 1);
    cache->entries[slot].item[sizeof cache->entries[slot].item - 1] = '\0';
    if (n > 0 && rows != NULL) {
        memcpy(cache->entries[slot].rows, rows, (size_t)n * sizeof *rows);
    }
    cache->entries[slot].row_count = n;
    cache->entries[slot].used = 1;
    cache->entries[slot].stamp = cache->clock++;
}

Boolean cloud_card_cache_get(const CloudCardCache *cache, const char *item,
                             CloudCardRow *rows_out, int *count_out)
{
    int slot = find_slot(cache, item);

    if (slot < 0) {
        return 0;
    }
    if (rows_out != NULL) {
        memcpy(rows_out, cache->entries[slot].rows,
              sizeof cache->entries[slot].rows);
    }
    if (count_out != NULL) {
        *count_out = cache->entries[slot].row_count;
    }
    return 1;
}

int cloud_card_cache_count(const CloudCardCache *cache)
{
    return cache->count;
}
