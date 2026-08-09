/*
 * axbinding.h - bind a validated AXPeek context to one live process lifetime.
 *
 * Portable and allocation-free: the guest stores only numeric Process Serial
 * Number and partition/context fingerprints.  A new PSN cannot inherit an old
 * binding even when Mac OS reuses the same partition and A5 addresses.
 */
#ifndef TBT_AXBINDING_H
#define TBT_AXBINDING_H

#include <stdint.h>

#define AX_BINDING_MAX 32

typedef struct {
    uint32_t psn_hi;
    uint32_t psn_lo;
    uint32_t process_lo;
    uint32_t process_size;
    uint32_t current_a5;
    uint32_t stack_base;
} ax_binding_entry;

typedef struct {
    ax_binding_entry entries[AX_BINDING_MAX];
    uint32_t         next;
} ax_binding_cache;

int ax_binding_matches(const ax_binding_cache *cache,
                       uint32_t psn_hi, uint32_t psn_lo,
                       uint32_t process_lo, uint32_t process_size,
                       uint32_t current_a5, uint32_t stack_base);
void ax_binding_record(ax_binding_cache *cache,
                       uint32_t psn_hi, uint32_t psn_lo,
                       uint32_t process_lo, uint32_t process_size,
                       uint32_t current_a5, uint32_t stack_base);

#endif /* TBT_AXBINDING_H */
