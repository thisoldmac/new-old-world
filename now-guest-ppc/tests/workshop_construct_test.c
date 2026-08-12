#include <assert.h>
#include <stdio.h>
#include <string.h>

#include "workshop_construct.h"

typedef struct Fixture {
    int controls;
    int noncontrol;
    int fail_after;
    int create_calls;
    char order[8];
    int order_len;
} Fixture;

static unsigned long begin(void *opaque)
{
    Fixture *f = (Fixture *)opaque;
    return (unsigned long)f->controls;
}

static int create(void *opaque)
{
    Fixture *f = (Fixture *)opaque;
    int made;
    f->create_calls++;
    f->noncontrol = 1;
    for (made = 0; made < 4; ++made) {
        if (made == f->fail_after) return 0;
        f->controls++;
    }
    return 1;
}

static void dispose(void *opaque)
{
    Fixture *f = (Fixture *)opaque;
    f->noncontrol = 0;
    f->order[f->order_len++] = 'd';
}

static void rollback(void *opaque, unsigned long marker)
{
    Fixture *f = (Fixture *)opaque;
    assert(!f->noncontrol);
    f->controls = (int)marker;
    f->order[f->order_len++] = 'r';
}

static NowWorkshopConstructOps ops_for(Fixture *f)
{
    NowWorkshopConstructOps ops;
    ops.context = f;
    ops.begin = begin;
    ops.create = create;
    ops.dispose = dispose;
    ops.rollback = rollback;
    return ops;
}

int main(void)
{
    int stage;

    for (stage = 0; stage < 4; ++stage) {
        Fixture f;
        NowWorkshopConstructOps ops;
        memset(&f, 0, sizeof f);
        f.controls = 3;
        f.fail_after = stage;
        ops = ops_for(&f);
        assert(!now_workshop_construct(&ops));
        assert(f.controls == 3);
        assert(!f.noncontrol);
        assert(memcmp(f.order, "dr", 2) == 0);

        f.fail_after = 99;
        f.order_len = 0;
        assert(now_workshop_construct(&ops));
        assert(f.controls == 7);
        assert(f.noncontrol);
        assert(f.order_len == 0);
        assert(f.create_calls == 2);

        /* The instance state is part of the same transaction: failure leaves
           it uncreated, retry commits it, and later selection reuses it. */
        {
            Fixture once;
            NowWorkshopConstructOps once_ops;
            int created = 0;

            memset(&once, 0, sizeof once);
            once.controls = 3;
            once.fail_after = stage;
            once_ops = ops_for(&once);
            assert(!now_workshop_ensure_constructed(&created, &once_ops));
            assert(!created);
            assert(once.controls == 3);
            once.fail_after = 99;
            assert(now_workshop_ensure_constructed(&created, &once_ops));
            assert(created);
            assert(once.create_calls == 2);
            assert(now_workshop_ensure_constructed(&created, &once_ops));
            assert(once.create_calls == 2);
        }
    }
    puts("workshop_construct_test ok");
    return 0;
}
