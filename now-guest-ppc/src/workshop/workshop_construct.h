#ifndef NOW_WORKSHOP_CONSTRUCT_H
#define NOW_WORKSHOP_CONSTRUCT_H

/* Toolbox-free coordinator for lazy Workshop construction. The adapter's
   begin/rollback pair snapshots and restores window-owned controls; dispose
   releases the module's UPPs, Handles, TextEdit state, model allocations, and
   callbacks. A failed create is never committed. */
typedef struct NowWorkshopConstructOps {
    void *context;
    unsigned long (*begin)(void *context);
    int (*create)(void *context);
    void (*dispose)(void *context);
    void (*rollback)(void *context, unsigned long marker);
} NowWorkshopConstructOps;

int now_workshop_construct(const NowWorkshopConstructOps *ops);
int now_workshop_ensure_constructed(int *created,
                                    const NowWorkshopConstructOps *ops);

#endif
