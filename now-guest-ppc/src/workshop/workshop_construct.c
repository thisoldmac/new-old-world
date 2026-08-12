#include "workshop_construct.h"

#include <stddef.h>

int now_workshop_construct(const NowWorkshopConstructOps *ops)
{
    unsigned long marker;

    if (ops == NULL || ops->begin == NULL || ops->create == NULL
            || ops->dispose == NULL || ops->rollback == NULL) {
        return 0;
    }
    marker = ops->begin(ops->context);
    if (ops->create(ops->context)) {
        return 1;
    }

    /* Non-control state may be referenced by a control's disposal callback,
       so each module decides its safe teardown order first. The registry then
       removes every still-live control born during this attempt. */
    ops->dispose(ops->context);
    ops->rollback(ops->context, marker);
    return 0;
}

int now_workshop_ensure_constructed(int *created,
                                    const NowWorkshopConstructOps *ops)
{
    if (created == NULL) {
        return 0;
    }
    if (*created) {
        return 1;
    }
    *created = now_workshop_construct(ops);
    return *created;
}
