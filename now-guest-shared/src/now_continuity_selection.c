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

int now_continuity_stub_same_item(const NowContinuityStubItem *a,
                                  const NowContinuityStubItem *b)
{
    if (a == NULL || b == NULL) {
        return a == b;
    }
    return a->volume_ref == b->volume_ref
        && a->dir_id == b->dir_id
        && a->is_folder == b->is_folder
        && strcmp(a->name, b->name) == 0;
}

int now_continuity_grab_confirm(const NowContinuityStubItem *serve,
                                int read_ok,
                                const NowContinuityStubItem *observed)
{
    if (serve == NULL) {
        return kNowGrabNoSelection;
    }
    if (!read_ok) {
        /* Reported as a stale selection rather than as a new code: the
           contract's refusal vocabulary is a closed set both halves already
           speak, and what the host must do about it — stop, do not transfer,
           the selection is not what you think — is the same sentence. The
           guest's log carries the difference for whoever is diagnosing. */
        return kNowGrabStaleSelection;
    }
    if (observed == NULL) {
        return kNowGrabNoSelection;
    }
    if (!now_continuity_stub_same_item(serve, observed)) {
        return kNowGrabStaleSelection;
    }
    return kNowGrabOK;
}

int now_continuity_grab_confirm_drag(const NowContinuityStubItem *serve,
                                     int read_ok,
                                     const NowContinuityStubItem *observed,
                                     unsigned long observed_seq)
{
    if (serve == NULL) {
        return kNowGrabNoSelection;
    }
    /* The wrong witness for this stub. Not a refusal the person caused. */
    if (serve->source != kNowStubSourceDrag || serve->drag_seq == 0) {
        return kNowGrabNoSelection;
    }
    if (!read_ok) {
        return kNowGrabStaleSelection;
    }
    if (observed == NULL) {
        return kNowGrabNoSelection;
    }
    /* THE SHARPER HALF. Same file is not enough: it must be the same
       DRAG, or a second pick-up of the same icon would be served under
       the first one's generation. */
    if (observed_seq != serve->drag_seq) {
        return kNowGrabStaleSelection;
    }
    if (!now_continuity_stub_same_item(serve, observed)) {
        return kNowGrabStaleSelection;
    }
    return kNowGrabOK;
}

int now_continuity_stub_observe(NowContinuityStubTable *table,
                                const NowContinuityStubItem *item)
{
    if (table == NULL) {
        return 0;
    }
    /* A DRAG-BOUND STUB IS NOT THE POLL'S TO OVERWRITE. The consent for
       this epoch's gesture is the drag; what the Finder's selection does
       after the release — the snap-back moving it, the desktop clearing
       it — is that gesture's noise, and observing it here is what handed
       the epoch-end grant hold a churned or empty table on 2026-08-17
       (the attended "the drag no longer names what it was given" chain).
       Only another drag (now_continuity_stub_observe_drag) or the epoch's
       own settle replaces a drag-sourced stub. A poll re-observing the
       SAME item still falls through to the silent field refresh below.

       DELIBERATE SPEC CHANGE: this reverses the earlier rule that a poll
       seeing a different file replaces a drag stub — the attended run
       proved that rule is how a crossing gesture loses its grant. */
    if (table->have_item && table->item.source == kNowStubSourceDrag
            && (item == NULL
                || !now_continuity_stub_same(&table->item, item))) {
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
        int was_source = table->item.source;
        unsigned long was_seq = table->item.drag_seq;

        table->item = *item;
        /* THE SOURCE BELONGS TO THE GENERATION. The poll's item is always
           selection-sourced; copying it wholesale over a generation the
           drag plane minted would demote that generation's source without
           moving the generation — and the host, the grant hold and the
           grab confirmation would then disagree about which witness to
           ask for a name none of them had republished. */
        table->item.source = was_source;
        table->item.drag_seq = was_seq;
        return 0;
    }
    table->item = *item;
    table->have_item = 1;
    table->generation++;
    return 1;
}

int now_continuity_stub_observe_drag(NowContinuityStubTable *table,
                                     const NowContinuityStubItem *item,
                                     unsigned long drag_seq)
{
    if (table == NULL || item == NULL || drag_seq == 0) {
        return 0;
    }
    /* Idempotent on the sequence, not on the item: see the header. */
    if (table->have_item
        && table->item.source == kNowStubSourceDrag
        && table->item.drag_seq == drag_seq) {
        return 0;
    }
    table->item = *item;
    table->item.source = kNowStubSourceDrag;
    table->item.drag_seq = drag_seq;
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

int now_continuity_selection_settle(NowContinuityStubTable *table,
                                    NowContinuityGrantHold *hold,
                                    unsigned long *table_epoch,
                                    unsigned long live_epoch,
                                    unsigned long now_ticks)
{
    if (table == NULL || table_epoch == NULL) {
        return 0;
    }
    if (live_epoch == *table_epoch) {
        return 0;
    }
    /* The grant comes out FIRST, while the table it is made of is still
       standing. A gesture may be in the air whichever way the epoch ended —
       disarm, lease expiry, a resident reset, the host walking away — so
       this is unconditional rather than a disarm handler's business. */
    if (*table_epoch != 0) {
        now_continuity_grant_hold(hold, table, now_ticks);
    }
    now_continuity_stub_reset(table, live_epoch);
    *table_epoch = live_epoch;
    return 1;
}

/* Has the held grant's window closed? Signed difference, so a TickCount
   that wrapped under a long uptime does not read as an expiry that will
   not arrive for two years. */
static int grant_expired(const NowContinuityGrantHold *hold,
                         unsigned long now_ticks)
{
    return (long)(now_ticks - hold->expires_at) > 0;
}

void now_continuity_epoch_ended(NowContinuityEndedEpoch *ended,
                                unsigned long epoch,
                                unsigned long generation,
                                unsigned long now_ticks)
{
    if (ended == NULL) {
        return;
    }
    if (epoch == 0) {
        /* Nothing ended. Recording a zero epoch would make every later
           drain believe it had a consent to publish under. */
        now_continuity_epoch_ended_release(ended);
        return;
    }
    ended->epoch = epoch;
    ended->generation = generation;
    ended->ended_at = now_ticks;
}

void now_continuity_epoch_ended_release(NowContinuityEndedEpoch *ended)
{
    if (ended == NULL) {
        return;
    }
    memset(ended, 0, sizeof *ended);
}

/* The same window as the grant's, measured from the moment the end was
   noticed. Signed, for the reason grant_expired is. */
static int ended_epoch_window_closed(const NowContinuityEndedEpoch *ended,
                                     unsigned long now_ticks)
{
    return (long)(now_ticks - (ended->ended_at + kNowContinuityGrantTicks)) > 0;
}

int now_continuity_stub_publish_post_epoch(NowContinuityStubTable *post,
                                           NowContinuityGrantHold *hold,
                                           const NowContinuityEndedEpoch *ended,
                                           const NowContinuityStubItem *item,
                                           unsigned long drag_seq,
                                           unsigned long now_ticks)
{
    unsigned long generation;

    if (post == NULL || ended == NULL || item == NULL || drag_seq == 0) {
        return 0;
    }
    if (ended->epoch == 0 || ended_epoch_window_closed(ended, now_ticks)) {
        return 0;
    }
    /* A folder is refused HERE for the reason the live drain refuses one:
       once, at the source, rather than at the host's bind and again at this
       guest's grab. */
    if (item->is_folder) {
        return 0;
    }
    /* Idempotent on the gesture, exactly like the live drain: the observer
       is edge-triggered, but a second drain of one drag must not mint a
       second number for it. */
    if (post->epoch == ended->epoch && post->have_item
        && post->item.source == kNowStubSourceDrag
        && post->item.drag_seq == drag_seq) {
        return 0;
    }
    /* A NUMBER NOBODY HAS PUBLISHED. The ended epoch's last generation is
       the floor; a second post-epoch mint under the same epoch counts on
       from the first, so two gestures cannot share a name. */
    generation = ended->generation;
    if (post->epoch == ended->epoch && post->generation > generation) {
        generation = post->generation;
    }
    now_continuity_stub_reset(post, ended->epoch);
    post->generation = generation + 1;
    post->item = *item;
    post->item.source = kNowStubSourceDrag;
    post->item.drag_seq = drag_seq;
    post->have_item = 1;
    /* AND IT IS GRANTABLE AT ONCE. Publishing a number this guest would
       refuse to serve is the defect being fixed, wearing different clothes:
       the host would bind it, ask for it, and be told bad-epoch. The window
       runs from the mint rather than from the epoch's end, because the
       gesture the person is holding is still in flight now. */
    now_continuity_grant_hold(hold, post, now_ticks);
    return 1;
}

int now_continuity_grab_resolve(NowContinuityStubTable *table,
                                NowContinuityGrantHold *hold,
                                unsigned long *table_epoch,
                                unsigned long live_epoch,
                                unsigned long asked_epoch,
                                unsigned long asked_generation,
                                unsigned long now_ticks,
                                const NowContinuityStubItem **item_out,
                                int *after_epoch_out)
{
    int verdict;

    /* BEFORE THE DECISION, NOT AFTER IT. A grab arrives on the same wire
       as the disarm that ended its epoch and is dispatched in the same
       pass, so the poll that used to own this transition has not run yet.
       Deciding first would read an empty hold and answer bad-epoch — the
       one refusal the contract says this window exists to prevent. */
    (void)now_continuity_selection_settle(table, hold, table_epoch,
                                          live_epoch, now_ticks);
    verdict = now_continuity_grab_check(table, live_epoch, asked_epoch,
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
