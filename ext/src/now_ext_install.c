#include "now_ext_install.h"

NowPeekTable *now_ext_install_transaction(const NowExtInstallOps *ops)
{
    NowPeekTable *table;
    int attempted_content = 0;
    int attempted_event = 0;
    int attempted_drag = 0;
    int attempted_cursor = 0;
    int attempted_liveness = 0;

    if (ops == NULL || ops->make_table == NULL || ops->drop_table == NULL
            || ops->prepare_content == NULL || ops->rollback_content == NULL
            || ops->prepare_event == NULL || ops->rollback_event == NULL
            || ops->prepare_drag == NULL || ops->rollback_drag == NULL
            || ops->prepare_cursor == NULL || ops->rollback_cursor == NULL
            || ops->prepare_liveness == NULL || ops->rollback_liveness == NULL
            || ops->publish == NULL) {
        return NULL;
    }

    table = ops->make_table(ops->context);
    if (table == NULL) {
        return NULL;
    }
    attempted_content = 1;
    if (!ops->prepare_content(ops->context, table)) goto fail;
    attempted_event = 1;
    if (!ops->prepare_event(ops->context, table)) goto fail;
    attempted_drag = 1;
    if (!ops->prepare_drag(ops->context, table)) goto fail;
    attempted_cursor = 1;
    if (!ops->prepare_cursor(ops->context, table)) goto fail;
    attempted_liveness = 1;
    if (!ops->prepare_liveness(ops->context, table)) goto fail;

    /* The sole commit boundary. A successful return transfers the table and
       every prepared subsystem to the resident component permanently. */
    if (ops->publish(ops->context, table)) {
        return table;
    }

fail:
    if (attempted_liveness) ops->rollback_liveness(ops->context, table);
    if (attempted_cursor) ops->rollback_cursor(ops->context, table);
    if (attempted_drag) ops->rollback_drag(ops->context, table);
    if (attempted_event) ops->rollback_event(ops->context, table);
    if (attempted_content) ops->rollback_content(ops->context, table);
    ops->drop_table(ops->context, table);
    return NULL;
}
