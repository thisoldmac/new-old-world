#include "now_continuity_selection.h"

#include <string.h>

void now_continuity_stub_reset(NowContinuityStubTable *table,
                               unsigned long epoch)
{
    if (table == NULL) {
        return;
    }
    memset(table, 0, sizeof *table);
    table->epoch = epoch;
    /* Generation starts at zero and the first observation makes it 1, so
       "1" always means the first thing this epoch saw. The contract's
       minimum is 1 for the same reason: a generation of 0 on the wire
       would be a stub nobody ever published. */
}

int now_continuity_stub_same(const NowContinuityStubItem *a,
                             const NowContinuityStubItem *b)
{
    if (a == NULL || b == NULL) {
        return a == b;
    }
    return a->volume_ref == b->volume_ref
        && a->dir_id == b->dir_id
        && a->is_folder == b->is_folder
        && a->modified == b->modified
        && strcmp(a->name, b->name) == 0;
}

int now_continuity_stub_observe(NowContinuityStubTable *table,
                                const NowContinuityStubItem *item)
{
    if (table == NULL) {
        return 0;
    }
    if (item == NULL) {
        if (!table->have_item) {
            return 0;               /* still empty; nothing to say */
        }
        table->have_item = 0;
        memset(&table->item, 0, sizeof table->item);
        table->generation++;
        return 1;
    }
    if (table->have_item && now_continuity_stub_same(&table->item, item)) {
        /* Same item — but copy it in anyway. The fields NOT compared
           (sizes, type, creator) can move under a Finder that leaves the
           date alone, and a stub the host already holds is not worth a
           generation. Refreshing them silently keeps the cache the grab
           serves from agreeing with the disk without republishing. */
        table->item = *item;
        return 0;
    }
    table->item = *item;
    table->have_item = 1;
    table->generation++;
    return 1;
}

int now_continuity_grab_check(const NowContinuityStubTable *table,
                              unsigned long live_epoch,
                              unsigned long asked_epoch,
                              unsigned long asked_generation)
{
    if (table == NULL) {
        return kNowGrabBadEpoch;
    }
    /* Epoch first, and against the LIVE epoch rather than the table's own.
       A table left behind by a finished session would otherwise keep
       answering for it, which is exactly the grant outliving its consent
       that the contract says cannot happen. */
    if (live_epoch == 0 || asked_epoch != live_epoch
        || table->epoch != live_epoch) {
        return kNowGrabBadEpoch;
    }
    if (!table->have_item || table->generation == 0) {
        return kNowGrabNoSelection;
    }
    if (asked_generation != table->generation) {
        return kNowGrabStaleSelection;
    }
    if (table->item.is_folder) {
        return kNowGrabFolderNotYet;
    }
    return kNowGrabOK;
}

const char *now_continuity_grab_code(int verdict)
{
    switch (verdict) {
    case kNowGrabBadEpoch:       return "bad-epoch";
    case kNowGrabStaleSelection: return "stale-selection";
    case kNowGrabNoSelection:    return "no-selection";
    case kNowGrabFolderNotYet:   return "folder-not-yet";
    default:                     return (const char *)0;
    }
}
