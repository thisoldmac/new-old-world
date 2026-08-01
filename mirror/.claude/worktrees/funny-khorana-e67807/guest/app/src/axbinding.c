/* axbinding.c - allocation-free process-lifetime context binding. */
#include "axbinding.h"

static int same_psn(const ax_binding_entry *entry,
                    uint32_t psn_hi, uint32_t psn_lo)
{
    return entry->psn_hi == psn_hi && entry->psn_lo == psn_lo;
}

int ax_binding_matches(const ax_binding_cache *cache,
                       uint32_t psn_hi, uint32_t psn_lo,
                       uint32_t process_lo, uint32_t process_size,
                       uint32_t current_a5, uint32_t stack_base)
{
    uint32_t i;

    if (cache == 0 || (psn_hi == 0 && psn_lo == 0)) {
        return 0;
    }
    for (i = 0; i < AX_BINDING_MAX; i++) {
        const ax_binding_entry *entry = &cache->entries[i];

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

void ax_binding_record(ax_binding_cache *cache,
                       uint32_t psn_hi, uint32_t psn_lo,
                       uint32_t process_lo, uint32_t process_size,
                       uint32_t current_a5, uint32_t stack_base)
{
    ax_binding_entry *entry = 0;
    uint32_t          i;

    if (cache == 0 || (psn_hi == 0 && psn_lo == 0)) {
        return;
    }
    for (i = 0; i < AX_BINDING_MAX; i++) {
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
        entry = &cache->entries[cache->next % AX_BINDING_MAX];
        cache->next = (cache->next + 1) % AX_BINDING_MAX;
    }
    entry->psn_hi = psn_hi;
    entry->psn_lo = psn_lo;
    entry->process_lo = process_lo;
    entry->process_size = process_size;
    entry->current_a5 = current_a5;
    entry->stack_base = stack_base;
}
