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

void now_continuity_grant_hold(NowContinuityGrantHold *hold,
                               const NowContinuityStubTable *table,
                               unsigned long now_ticks)
{
    if (hold == NULL) {
        return;
    }
    if (table == NULL || !table->have_item || table->epoch == 0
        || table->generation == 0) {
        /* Nothing was grantable, so nothing is held. An empty hold is
           written rather than left alone: the previous epoch's grant must
           not survive an epoch that ended holding nothing. */
        now_continuity_grant_release(hold);
        return;
    }
    hold->epoch = table->epoch;
    hold->generation = table->generation;
    hold->expires_at = now_ticks + kNowContinuityGrantTicks;
    hold->item = table->item;
}

void now_continuity_grant_release(NowContinuityGrantHold *hold)
{
    if (hold == NULL) {
        return;
    }
    memset(hold, 0, sizeof *hold);
}

/* Has the held grant's window closed? Signed difference, so a TickCount
   that wrapped under a long uptime does not read as an expiry that will
   not arrive for two years. */
static int grant_expired(const NowContinuityGrantHold *hold,
                         unsigned long now_ticks)
{
    return (long)(now_ticks - hold->expires_at) > 0;
}

int now_continuity_grab_resolve(const NowContinuityStubTable *table,
                                const NowContinuityGrantHold *hold,
                                unsigned long live_epoch,
                                unsigned long asked_epoch,
                                unsigned long asked_generation,
                                unsigned long now_ticks,
                                const NowContinuityStubItem **item_out,
                                int *after_epoch_out)
{
    int verdict = now_continuity_grab_check(table, live_epoch, asked_epoch,
                                            asked_generation);

    if (item_out != NULL) {
        *item_out = (const NowContinuityStubItem *)0;
    }
    if (after_epoch_out != NULL) {
        *after_epoch_out = 0;
    }
    if (verdict == kNowGrabOK) {
        if (item_out != NULL) {
            *item_out = &table->item;
        }
        return kNowGrabOK;
    }
    /* ONLY bad-epoch opens this door. A stale generation under a LIVE
       epoch is still stale — the person is looking at something else on a
       machine that is still theirs — and a folder is still a folder. */
    if (verdict != kNowGrabBadEpoch || hold == NULL || hold->epoch == 0) {
        return verdict;
    }
    if (asked_epoch != hold->epoch || asked_generation != hold->generation) {
        return verdict;
    }
    if (grant_expired(hold, now_ticks)) {
        return kNowGrabGrantExpired;
    }
    if (hold->item.is_folder) {
        return kNowGrabFolderNotYet;
    }
    if (item_out != NULL) {
        *item_out = &hold->item;
    }
    if (after_epoch_out != NULL) {
        *after_epoch_out = 1;
    }
    return kNowGrabOK;
}

const char *now_continuity_grab_code(int verdict)
{
    switch (verdict) {
    case kNowGrabBadEpoch:       return "bad-epoch";
    case kNowGrabGrantExpired:   return "grant-expired";
    case kNowGrabStaleSelection: return "stale-selection";
    case kNowGrabNoSelection:    return "no-selection";
    case kNowGrabFolderNotYet:   return "folder-not-yet";
    default:                     return (const char *)0;
    }
}
