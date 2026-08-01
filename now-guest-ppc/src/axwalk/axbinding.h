#ifndef NOW_AXBINDING_H
#define NOW_AXBINDING_H

/* Binding a validated context to one process LIFETIME, not one process
   number. Ported from mirror/guest/app/src/axbinding.c.

   The defect this exists to prevent: a PSN is a number, Mac OS reuses
   partitions, and a new process can end up with the same PSN, the same
   partition base and even the same A5 as one that died. A reference
   held across that boundary would resolve, cleanly, against the wrong
   application. So a binding is the whole tuple - PSN plus the partition
   and context fingerprints it was validated against - and a match means
   all of it agreed, not just the number.

   Allocation-free and portable: numbers only, no Toolbox, no pointers
   into anything. */

enum {
    kNowAxBindingMax = 32         /* matches the anchor table's slot count */
};

typedef struct {
    unsigned long psn_hi;
    unsigned long psn_lo;
    unsigned long process_lo;
    unsigned long process_size;
    unsigned long current_a5;
    unsigned long stack_base;
} NowAxBindingEntry;

typedef struct {
    NowAxBindingEntry entries[kNowAxBindingMax];
    unsigned long     next;       /* round-robin eviction cursor */
} NowAxBindingCache;

/* Nonzero when this exact tuple was recorded and has not been
   overwritten. A zero PSN never matches: 0/0 is the empty slot. */
int now_ax_binding_matches(const NowAxBindingCache *cache,
                           unsigned long psn_hi, unsigned long psn_lo,
                           unsigned long process_lo,
                           unsigned long process_size,
                           unsigned long current_a5,
                           unsigned long stack_base);

/* Records (or replaces) this PSN's binding. One entry per PSN, so a
   process whose partition moved does not accumulate ghosts. */
void now_ax_binding_record(NowAxBindingCache *cache,
                           unsigned long psn_hi, unsigned long psn_lo,
                           unsigned long process_lo,
                           unsigned long process_size,
                           unsigned long current_a5,
                           unsigned long stack_base);

#endif /* NOW_AXBINDING_H */
