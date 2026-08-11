#include <assert.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "now_ext_install.h"

enum {
    kFailTable = 0,
    kFailContent,
    kFailEvent,
    kFailDrag,
    kFailCursor,
    kFailContinuity,
    kFailLiveness,
    kFailPublish,
    kSucceed
};

typedef struct Fixture {
    int fail_at;
    int live_table;
    int live[6];
    int published;
    char rollback[16];
    int rollback_len;
} Fixture;

static NowPeekTable *make_table(void *opaque)
{
    Fixture *f = (Fixture *)opaque;
    if (f->fail_at == kFailTable) return NULL;
    f->live_table = 1;
    return (NowPeekTable *)calloc(1, sizeof(NowPeekTable));
}

static void drop_table(void *opaque, NowPeekTable *table)
{
    Fixture *f = (Fixture *)opaque;
    f->live_table = 0;
    free(table);
}

static int prepare(Fixture *f, int slot, int fail_at)
{
    f->live[slot] = 1;       /* failure injection catches partial prepare */
    return f->fail_at != fail_at;
}

static void rollback(Fixture *f, int slot, char mark)
{
    f->live[slot] = 0;
    f->rollback[f->rollback_len++] = mark;
    f->rollback[f->rollback_len] = '\0';
}

#define STAGE(NAME, SLOT, FAIL, MARK) \
    static int prepare_##NAME(void *o, NowPeekTable *t) \
    { (void)t; return prepare((Fixture *)o, SLOT, FAIL); } \
    static void rollback_##NAME(void *o, NowPeekTable *t) \
    { (void)t; rollback((Fixture *)o, SLOT, MARK); }

STAGE(content, 0, kFailContent, 'c')
STAGE(event, 1, kFailEvent, 'e')
STAGE(drag, 2, kFailDrag, 'd')
STAGE(cursor, 3, kFailCursor, 'u')
STAGE(continuity, 4, kFailContinuity, 'n')
STAGE(liveness, 5, kFailLiveness, 'l')

static int publish(void *opaque, NowPeekTable *table)
{
    Fixture *f = (Fixture *)opaque;
    (void)table;
    if (f->fail_at == kFailPublish) return 0;
    f->published = 1;
    return 1;
}

static NowExtInstallOps ops_for(Fixture *f)
{
    NowExtInstallOps ops;
    memset(&ops, 0, sizeof ops);
    ops.context = f;
    ops.make_table = make_table;
    ops.drop_table = drop_table;
    ops.prepare_content = prepare_content;
    ops.rollback_content = rollback_content;
    ops.prepare_event = prepare_event;
    ops.rollback_event = rollback_event;
    ops.prepare_drag = prepare_drag;
    ops.rollback_drag = rollback_drag;
    ops.prepare_cursor = prepare_cursor;
    ops.rollback_cursor = rollback_cursor;
    ops.prepare_continuity = prepare_continuity;
    ops.rollback_continuity = rollback_continuity;
    ops.prepare_liveness = prepare_liveness;
    ops.rollback_liveness = rollback_liveness;
    ops.publish = publish;
    return ops;
}

static void assert_failed_stage(int fail_at, const char *rollback_order)
{
    Fixture f;
    NowExtInstallOps ops;
    int i;
    memset(&f, 0, sizeof f);
    f.fail_at = fail_at;
    ops = ops_for(&f);
    assert(now_ext_install_transaction(&ops) == NULL);
    assert(!f.live_table);
    assert(!f.published);
    for (i = 0; i < 6; ++i) assert(!f.live[i]);
    assert(strcmp(f.rollback, rollback_order) == 0);
}

int main(void)
{
    Fixture success;
    NowExtInstallOps ops;
    NowPeekTable *table;
    int i;

    assert_failed_stage(kFailTable, "");
    assert_failed_stage(kFailContent, "c");
    assert_failed_stage(kFailEvent, "ec");
    assert_failed_stage(kFailDrag, "dec");
    assert_failed_stage(kFailCursor, "udec");
    assert_failed_stage(kFailContinuity, "nudec");
    assert_failed_stage(kFailLiveness, "lnudec");
    assert_failed_stage(kFailPublish, "lnudec");

    memset(&success, 0, sizeof success);
    success.fail_at = kSucceed;
    ops = ops_for(&success);
    table = now_ext_install_transaction(&ops);
    assert(table != NULL);
    assert(success.live_table && success.published);
    for (i = 0; i < 6; ++i) assert(success.live[i]);
    assert(success.rollback_len == 0);
    free(table);
    puts("now_ext_install_test ok");
    return 0;
}
