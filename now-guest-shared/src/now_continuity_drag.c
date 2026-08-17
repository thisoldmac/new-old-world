#include "now_continuity_drag.h"

#include <string.h>

void now_continuity_drag_reset(NowContinuityDragState *st)
{
    if (st == NULL) {
        return;
    }
    memset(st, 0, sizeof *st);
    st->state = kNowDragIdle;
    st->last_verdict = kNowDragOK;
}

int now_continuity_drag_size_ok(const NowContinuityOfferItem *item)
{
    long total;

    if (item == NULL) {
        return 0;
    }
    /* Both forks cross the same lane, so the sum is what the nested
       promise has to sit through. A resource fork the host never
       measured counts as nothing here rather than as unknown: the
       offer's have_resource_size flag is the host saying it did not
       look, and refusing on a number nobody produced would refuse
       every plain data file. The lane's own timeout remains the
       backstop for a size that turns out to be a lie. */
    total = item->data_size;
    if (total < 0) {
        return 0;
    }
    if (item->have_resource_size && item->resource_size > 0) {
        if (item->resource_size > kNowContinuityDragPromiseCapBytes - total) {
            return 0;
        }
        total += item->resource_size;
    }
    return total <= kNowContinuityDragPromiseCapBytes;
}

int now_continuity_drag_request(NowContinuityDragState *st,
                                const NowContinuityOfferTable *table,
                                unsigned long live_epoch,
                                unsigned long now_ticks)
{
    unsigned long epoch = 0, generation = 0;

    if (st == NULL || table == NULL) {
        return kNowDragNoOffer;
    }
    /* Busy is asked FIRST, before anything about the offer. A second
       arm must not be able to report a fresher refusal than the drag
       it would have trampled - and more to the point, must not be able
       to overwrite the identity copy the drag in flight is promising
       against. */
    if (st->state != kNowDragIdle) {
        return kNowDragBusy;
    }
    if (!now_continuity_offer_grab_ready(table, live_epoch, &epoch,
                                         &generation)) {
        return kNowDragNoOffer;
    }
    if (table->item.is_folder) {
        return kNowDragFolder;
    }
    if (!now_continuity_drag_size_ok(&table->item)) {
        return kNowDragTooLarge;
    }

    st->item = table->item;
    st->epoch = epoch;
    st->generation = generation;
    st->armed_at = now_ticks;
    /* Cleared, not left: this state struct is reused for the life of the
       application, and a stale gesture id from an earlier host-driven
       drag would join a console drag to a crossing that has nothing to
       do with it. */
    st->drag_seq = 0;
    st->host_driven = 0;
    st->cancel_requested = 0;
    st->promise_asked = 0;
    st->promise_settled = 0;
    st->last_verdict = kNowDragOK;
    st->state = kNowDragWaitingButton;
    return kNowDragOK;
}

int now_continuity_drag_host_begin(NowContinuityDragState *st,
                                   const NowContinuityOfferItem *item,
                                   unsigned long epoch,
                                   unsigned long live_epoch,
                                   unsigned long drag_seq)
{
    if (st == NULL || item == NULL) {
        return kNowDragNoOffer;
    }
    /* Busy first, for request()'s reason: a second beginning must not be
       able to overwrite the identity copy the drag in flight is
       promising against. */
    if (st->state != kNowDragIdle) {
        return kNowDragBusy;
    }
    /* THE EPOCH IS CHECKED AGAINST THE LIVE ONE, not merely for being
       non-zero. This drag is steered by the Continuity plane, and the
       plane belongs to an epoch: a drag begun under a dead epoch would
       enter TrackDrag with an input proc reading a cell nobody is
       writing, and would hang on the Manager's own sample of a mouse
       that never moves. That is the 2026-08-17 wall, re-entered
       voluntarily. */
    if (epoch == 0 || live_epoch == 0 || epoch != live_epoch) {
        return kNowDragBadEpoch;
    }
    if (item->is_folder) {
        return kNowDragFolder;
    }
    if (!now_continuity_drag_size_ok(item)) {
        return kNowDragTooLarge;
    }

    st->item = *item;
    st->epoch = epoch;
    /* NO GENERATION. A hostDragBegin does not mint one and does not
       carry one: the bytes are fetched from whatever the host's offer
       table holds for this epoch, which is the same authority
       `offer --take` already reads. Inventing a number here would be a
       second name for one item — the drift continuity.dragBegin's
       schema refuses in the mirrored direction. */
    st->generation = 0;
    st->armed_at = 0;
    st->drag_seq = drag_seq;
    st->host_driven = 1;
    st->cancel_requested = 0;
    st->promise_asked = 0;
    st->promise_settled = 0;
    st->last_verdict = kNowDragOK;
    st->state = kNowDragTracking;
    return kNowDragOK;
}

int now_continuity_drag_tick(NowContinuityDragState *st, int button_down,
                             unsigned long now_ticks)
{
    if (st == NULL || st->state != kNowDragWaitingButton) {
        return kNowDragTickWait;
    }
    if (st->cancel_requested) {
        st->state = kNowDragIdle;
        st->last_verdict = kNowDragCancelled;
        st->cancel_requested = 0;
        return kNowDragTickExpire;
    }
    if (button_down) {
        st->state = kNowDragTracking;
        return kNowDragTickStart;
    }
    /* Unsigned subtraction, so a TickCount wrap reads as a small
       elapsed rather than an enormous one - the arm survives the wrap
       instead of expiring the instant it happens.

       THE MASK IS NOT DECORATION. The clock here is TickCount, which is
       32 bits wide on the machine this runs on; `unsigned long` is that
       width there and SIXTY-FOUR on the host cc that watches this file
       fail. Without the mask the wrap case is simply a different
       calculation in the test than in the product, and the guard reads
       green having never been exercised - the same shape as a gate that
       never reached the thing it names. Stating the width makes the one
       arithmetic run in both places. */
    if (((now_ticks - st->armed_at) & 0xFFFFFFFFUL)
        >= (unsigned long)kNowContinuityDragArmTicks) {
        st->state = kNowDragIdle;
        st->last_verdict = kNowDragButtonNeverCame;
        return kNowDragTickExpire;
    }
    return kNowDragTickWait;
}

void now_continuity_drag_start_failed(NowContinuityDragState *st)
{
    if (st == NULL) {
        return;
    }
    st->state = kNowDragIdle;
    st->last_verdict = kNowDragDragFailed;
    st->cancel_requested = 0;
}

int now_continuity_drag_promise_begin(NowContinuityDragState *st)
{
    if (st == NULL || st->state != kNowDragTracking) {
        return 0;
    }
    st->promise_asked = 1;
    if (st->cancel_requested) {
        /* A cancel that landed between the drop and this callback. The
           Finder gets a refusal for the flavor and the drag ends
           cleanly, which is the whole point of naming the cancel path
           a deliverable: the alternative is a promise that streams a
           file nobody is still asking for. */
        return 0;
    }
    st->state = kNowDragPromising;
    return 1;
}

void now_continuity_drag_promise_end(NowContinuityDragState *st, int ok)
{
    if (st == NULL || st->state != kNowDragPromising) {
        return;
    }
    st->promise_settled = ok ? 1 : 0;
    /* Back to Tracking, not to Idle: TrackDrag has not returned yet and
       it is the only thing that may declare the drag over. Ending here
       would leave the Drag Manager holding a drag this side already
       forgot. */
    st->state = kNowDragTracking;
}

int now_continuity_drag_should_abort(const NowContinuityDragState *st)
{
    return st != NULL && st->cancel_requested != 0;
}

int now_continuity_drag_ended(NowContinuityDragState *st, int track_ok,
                              int toolbox_button_at_start)
{
    int verdict;

    if (st == NULL) {
        return kNowDragNotDragging;
    }
    if (st->state != kNowDragTracking && st->state != kNowDragPromising) {
        return kNowDragNotDragging;
    }

    if (st->promise_settled) {
        verdict = kNowDragOK;
    } else if (st->cancel_requested) {
        verdict = kNowDragCancelled;
    } else if (st->promise_asked) {
        /* Asked and not settled: the stream is what failed. Checked
           before the not-asked case so a promise that began and broke
           can never be reported as a receiver that stayed silent. */
        verdict = kNowDragTransferFailed;
    } else if (!track_ok && !toolbox_button_at_start) {
        /* No drop, and this Mac's own button was up when tracking began.
           Ranked BELOW the three above on purpose: a settled promise, a
           cancel we asked for, and a stream that broke are all things we
           know happened, and the state of a button before any of them is
           not evidence against them. It outranks plain `cancelled` for
           the opposite reason - once nothing else is known, "the button
           was never real" is the more specific of the two, and the less
           specific word is what made the first live run unreadable. */
        verdict = kNowDragButtonNotReal;
    } else if (!track_ok) {
        verdict = kNowDragCancelled;
    } else {
        verdict = kNowDragPromiseNeverAsked;
    }

    st->state = kNowDragIdle;
    st->cancel_requested = 0;
    st->last_verdict = verdict;
    return verdict;
}

int now_continuity_drag_cancel(NowContinuityDragState *st)
{
    if (st == NULL || st->state == kNowDragIdle) {
        return kNowDragNotDragging;
    }
    /* Before the button ripens, this side still owns the loop and can
       simply end it. Afterwards the Drag Manager owns it, so all a
       cancel can do is set the flag the pumped stream and TrackDrag's
       return both read. */
    st->cancel_requested = 1;
    if (st->state == kNowDragWaitingButton) {
        st->state = kNowDragIdle;
        st->last_verdict = kNowDragCancelled;
        st->cancel_requested = 0;
    }
    return kNowDragOK;
}

void now_continuity_drag_forget(NowContinuityDragState *st)
{
    if (st == NULL) {
        return;
    }
    if (st->state == kNowDragTracking || st->state == kNowDragPromising) {
        /* The Drag Manager still owns the loop; asking is all that is
           available, and TrackDrag's return will find the flag. Wiping
           the state here would leave the promise callback reading a
           cleared identity mid-stream. */
        st->cancel_requested = 1;
        return;
    }
    now_continuity_drag_reset(st);
    st->last_verdict = kNowDragCancelled;
}

const char *now_continuity_drag_code(int verdict)
{
    switch (verdict) {
    case kNowDragOK:
        return "ok";
    case kNowDragNoOffer:
        return "no-offer";
    case kNowDragFolder:
        return "folder";
    case kNowDragTooLarge:
        return "too-large";
    case kNowDragBusy:
        return "busy";
    case kNowDragButtonNeverCame:
        return "button-never-came";
    case kNowDragDragFailed:
        return "drag-failed";
    case kNowDragTransferFailed:
        return "transfer-failed";
    case kNowDragCancelled:
        return "cancelled";
    case kNowDragNotDragging:
        return "not-dragging";
    case kNowDragPromiseNeverAsked:
        return "promise-never-asked";
    case kNowDragButtonNotReal:
        return "button-not-real";
    case kNowDragBadEpoch:
        return "bad-epoch";
    default:
        break;
    }
    return "unknown";
}

const char *now_continuity_drag_state_name(int state)
{
    switch (state) {
    case kNowDragIdle:
        return "idle";
    case kNowDragWaitingButton:
        return "waiting-button";
    case kNowDragTracking:
        return "tracking";
    case kNowDragPromising:
        return "promising";
    default:
        break;
    }
    return "unknown";
}
