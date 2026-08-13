#include "now_continuity_keyboard_logic.h"

#include <string.h>

static int sequence_newer(NowPeekU32 candidate, NowPeekU32 baseline)
{
    NowPeekU32 distance = candidate - baseline;
    return candidate != baseline && distance < 0x80000000UL;
}

static NowPeekU32 sequence_next(NowPeekU32 value)
{
    value++;
    return value == 0 ? 1 : value;
}

static int action_valid(NowPeekU32 action)
{
    return action == (NowPeekU32)kNowPeekContinuityKeyDown
        || action == (NowPeekU32)kNowPeekContinuityKeyUp
        || action == (NowPeekU32)kNowPeekContinuityKeyRepeat;
}

static void abandon_pending(NowPeekContinuityCell *cell)
{
    cell->key_floor_seq = cell->key_write_seq;
    cell->key_flushes++;
}

int now_continuity_keyboard_enqueue(
    NowPeekContinuityCell *cell,
    NowPeekU32 generation,
    NowPeekU32 target_a5,
    NowPeekU32 target_psn_high,
    NowPeekU32 target_psn_low,
    NowPeekU32 action,
    NowPeekU32 key_code,
    NowPeekU32 character,
    NowPeekU32 modifiers)
{
    NowPeekU32 base;
    NowPeekU32 used;
    NowPeekU32 next;
    NowPeekContinuityKeyEntry *slot;

    if (cell == NULL || generation == 0 || target_a5 == 0
            || !action_valid(action) || key_code > 127u
            || character > 255u)
        return kNowContinuityKeyEnqueueInvalid;
    if (cell->key_target_a5 != 0
            && (cell->key_target_a5 != target_a5
                || cell->key_target_psn_high != target_psn_high
                || cell->key_target_psn_low != target_psn_low))
        abandon_pending(cell);
    cell->key_target_a5 = target_a5;
    cell->key_target_psn_high = target_psn_high;
    cell->key_target_psn_low = target_psn_low;

    base = sequence_newer(cell->key_floor_seq, cell->key_read_seq)
        ? cell->key_floor_seq : cell->key_read_seq;
    used = cell->key_write_seq - base;
    if (used >= (NowPeekU32)kNowPeekContinuityKeyQueueCapacity) {
        cell->key_dropped++;
        return kNowContinuityKeyEnqueueFull;
    }
    next = sequence_next(cell->key_write_seq);
    slot = &cell->key_queue[
        (next - 1u) % (NowPeekU32)kNowPeekContinuityKeyQueueCapacity];
    slot->queue_seq = 0;                 /* invalidate before reuse */
    slot->generation = generation;
    slot->target_a5 = target_a5;
    slot->target_psn_high = target_psn_high;
    slot->target_psn_low = target_psn_low;
    slot->action = action;
    slot->key_code = key_code;
    slot->character = character;
    slot->modifiers = modifiers;
    slot->queue_seq = next;              /* commit the slot last */
    cell->key_write_seq = next;          /* publish availability last */
    cell->key_enqueued++;
    return kNowContinuityKeyEnqueueOK;
}

void now_continuity_keyboard_flush(NowPeekContinuityCell *cell)
{
    if (cell == NULL)
        return;
    abandon_pending(cell);
    cell->key_target_a5 = 0;
    cell->key_target_psn_high = 0;
    cell->key_target_psn_low = 0;
}

int now_continuity_keyboard_peek(
    NowPeekContinuityCell *cell,
    NowPeekU32 current_a5,
    NowContinuityKeySnapshot *out)
{
    NowPeekU32 next;
    const NowPeekContinuityKeyEntry *slot;

    if (cell == NULL || out == NULL || current_a5 == 0)
        return kNowContinuityKeyPeekNone;
    if (sequence_newer(cell->key_floor_seq, cell->key_read_seq))
        cell->key_read_seq = cell->key_floor_seq;
    if (cell->key_read_seq == cell->key_write_seq)
        return kNowContinuityKeyPeekNone;
    next = sequence_next(cell->key_read_seq);
    slot = &cell->key_queue[
        (next - 1u) % (NowPeekU32)kNowPeekContinuityKeyQueueCapacity];
    if (slot->queue_seq != next)
        return kNowContinuityKeyPeekNone;
    if (slot->target_a5 != current_a5)
        return kNowContinuityKeyPeekNone;

    out->queue_seq = slot->queue_seq;
    out->generation = slot->generation;
    out->target_a5 = slot->target_a5;
    out->target_psn_high = slot->target_psn_high;
    out->target_psn_low = slot->target_psn_low;
    out->action = slot->action;
    out->key_code = slot->key_code;
    out->character = slot->character;
    out->modifiers = slot->modifiers;
    if (slot->queue_seq != next || !action_valid(out->action)
            || out->generation == 0 || out->key_code > 127u
            || out->character > 255u)
        return kNowContinuityKeyPeekInvalid;
    return kNowContinuityKeyPeekReady;
}

void now_continuity_keyboard_commit(
    NowPeekContinuityCell *cell,
    const NowContinuityKeySnapshot *event,
    NowPeekI32 error)
{
    if (cell == NULL || event == NULL
            || event->queue_seq != sequence_next(cell->key_read_seq))
        return;
    cell->key_read_seq = event->queue_seq;
    if (error == (NowPeekI32)kNowPeekContinuityKeyErrorNone) {
        cell->key_applied_generation = event->generation;
        cell->key_applied++;
        cell->key_last_error = 0;
    } else {
        cell->key_failed_generation = event->generation;
        cell->key_failures++;
        cell->key_last_error = error;
    }
}

void now_continuity_keyboard_resident_flush(NowPeekContinuityCell *cell)
{
    if (cell == NULL)
        return;
    cell->key_read_seq = cell->key_write_seq;
}
