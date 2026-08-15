#ifndef NOW_EXT_INSTALL_H
#define NOW_EXT_INSTALL_H

#include "peek_table.h"

/* The resident's construction transaction. Every prepare callback may leave
   private state behind even when it reports failure; the coordinator therefore
   rolls back the attempted stage as well as every earlier stage. `publish` is
   the only callback allowed to make the component externally discoverable and
   must either commit completely or restore its own publication attempt. */
typedef struct NowExtInstallOps {
    void *context;
    NowPeekTable *(*make_table)(void *context);
    void (*drop_table)(void *context, NowPeekTable *table);
    int (*prepare_content)(void *context, NowPeekTable *table);
    void (*rollback_content)(void *context, NowPeekTable *table);
    int (*prepare_event)(void *context, NowPeekTable *table);
    void (*rollback_event)(void *context, NowPeekTable *table);
    int (*prepare_drag)(void *context, NowPeekTable *table);
    void (*rollback_drag)(void *context, NowPeekTable *table);
    int (*prepare_cursor)(void *context, NowPeekTable *table);
    void (*rollback_cursor)(void *context, NowPeekTable *table);
    int (*prepare_continuity)(void *context, NowPeekTable *table);
    void (*rollback_continuity)(void *context, NowPeekTable *table);
    int (*prepare_liveness)(void *context, NowPeekTable *table);
    void (*rollback_liveness)(void *context, NowPeekTable *table);
    int (*publish)(void *context, NowPeekTable *table);
} NowExtInstallOps;

NowPeekTable *now_ext_install_transaction(const NowExtInstallOps *ops);

#endif
