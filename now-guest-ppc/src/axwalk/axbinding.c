/* Process-lifetime context binding. See axbinding.h. */

#include "axbinding.h"

static int same_psn(const NowAxBindingEntry *entry,
                    unsigned long psn_hi, unsigned long psn_lo)
{
    return entry->psn_hi == psn_hi && entry->psn_lo == psn_lo;
}

int now_ax_binding_matches(const NowAxBindingCache *cache,
                           unsigned long psn_hi, unsigned long psn_lo,
                           unsigned long process_lo,
                           unsigned long process_size,
                           unsigned long current_a5,
                           unsigned long stack_base)
{
    unsigned long i;

    if (cache == 0 || (psn_hi == 0 && psn_lo == 0)) {
        return 0;
    }
    for (i = 0; i < kNowAxBindingMax; i++) {
        const NowAxBindingEntry *entry = &cache->entries[i];

        /* Every field, deliberately. A partial match is what a recycled
           PSN looks like, and it is exactly the case to refuse. */
        if (same_psn(entry, psn_hi, psn_lo)
            && entry->process_lo == process_lo
            && entry->process_size == process_size
            && entry->current_a5 == current_a5
            && entry->stack_base == stack_base) {
            return 1;
        }
    }
    return 0;
}

void now_ax_binding_record(NowAxBindingCache *cache,
                           unsigned long psn_hi, unsigned long psn_lo,
                           unsigned long process_lo,
                           unsigned long process_size,
                           unsigned long current_a5,
                           unsigned long stack_base)
{
    NowAxBindingEntry *entry = 0;
    unsigned long      i;

    if (cache == 0 || (psn_hi == 0 && psn_lo == 0)) {
        return;
    }
    /* This PSN's own entry wins; otherwise the first empty one; only if
       neither exists does anything get evicted. */
    for (i = 0; i < kNowAxBindingMax; i++) {
        if (same_psn(&cache->entries[i], psn_hi, psn_lo)) {
            entry = &cache->entries[i];
            break;
        }
        if (entry == 0 && cache->entries[i].psn_hi == 0
            && cache->entries[i].psn_lo == 0) {
            entry = &cache->entries[i];
        }
    }
    if (entry == 0) {
        entry = &cache->entries[cache->next % kNowAxBindingMax];
        cache->next = (cache->next + 1) % kNowAxBindingMax;
    }
    entry->psn_hi = psn_hi;
    entry->psn_lo = psn_lo;
    entry->process_lo = process_lo;
    entry->process_size = process_size;
    entry->current_a5 = current_a5;
    entry->stack_base = stack_base;
}
