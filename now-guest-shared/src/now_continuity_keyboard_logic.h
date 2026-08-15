#ifndef NOW_CONTINUITY_KEYBOARD_LOGIC_H
#define NOW_CONTINUITY_KEYBOARD_LOGIC_H

#include "peek_table.h"

typedef struct {
    NowPeekU32 queue_seq;
    NowPeekU32 generation;
    NowPeekU32 target_a5;
    NowPeekU32 target_psn_high;
    NowPeekU32 target_psn_low;
    NowPeekU32 action;
    NowPeekU32 key_code;
    NowPeekU32 character;
    NowPeekU32 modifiers;
} NowContinuityKeySnapshot;

enum {
    kNowContinuityKeyEnqueueInvalid = -1,
    kNowContinuityKeyEnqueueFull = 0,
    kNowContinuityKeyEnqueueOK = 1
};

enum {
    kNowContinuityKeyPeekInvalid = -1,
    kNowContinuityKeyPeekNone = 0,
    kNowContinuityKeyPeekReady = 1
};

/* Application-side operations. A changed target first advances the queue
   floor, so an event addressed to the old foreground process cannot reach the
   new one. */
int now_continuity_keyboard_enqueue(
    NowPeekContinuityCell *cell,
    NowPeekU32 generation,
    NowPeekU32 target_a5,
    NowPeekU32 target_psn_high,
    NowPeekU32 target_psn_low,
    NowPeekU32 action,
    NowPeekU32 key_code,
    NowPeekU32 character,
    NowPeekU32 modifiers);
void now_continuity_keyboard_flush(NowPeekContinuityCell *cell);

/* Resident-side operations. Peek returns Ready only in the addressed A5
   world; no other process consumes or rejects somebody else's key. */
int now_continuity_keyboard_peek(
    NowPeekContinuityCell *cell,
    NowPeekU32 current_a5,
    NowContinuityKeySnapshot *out);
void now_continuity_keyboard_commit(
    NowPeekContinuityCell *cell,
    const NowContinuityKeySnapshot *event,
    NowPeekI32 error);
void now_continuity_keyboard_resident_flush(NowPeekContinuityCell *cell);

#endif /* NOW_CONTINUITY_KEYBOARD_LOGIC_H */
