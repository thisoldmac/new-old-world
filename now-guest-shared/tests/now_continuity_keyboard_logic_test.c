#include <stdio.h>
#include <string.h>

#include "now_continuity_keyboard_logic.h"

#define CHECK(expr) do {                                                \
    if (!(expr)) {                                                      \
        fprintf(stderr, "line %d: %s\n", __LINE__, #expr);            \
        return 1;                                                       \
    }                                                                  \
} while (0)

static int enqueue(NowPeekContinuityCell *cell, NowPeekU32 generation,
                   NowPeekU32 a5, NowPeekU32 action)
{
    return now_continuity_keyboard_enqueue(
        cell, generation, a5, 0, a5 + 1u, action, 12, 'q', 0x300u);
}

static int test_order_and_results(void)
{
    NowPeekContinuityCell cell;
    NowContinuityKeySnapshot event;

    memset(&cell, 0, sizeof cell);
    CHECK(enqueue(&cell, 41, 0x1234, kNowPeekContinuityKeyDown)
          == kNowContinuityKeyEnqueueOK);
    CHECK(enqueue(&cell, 42, 0x1234, kNowPeekContinuityKeyUp)
          == kNowContinuityKeyEnqueueOK);
    CHECK(now_continuity_keyboard_peek(&cell, 0x9999, &event)
          == kNowContinuityKeyPeekNone);
    CHECK(now_continuity_keyboard_peek(&cell, 0x1234, &event)
          == kNowContinuityKeyPeekReady);
    CHECK(event.generation == 41);
    CHECK(event.action == kNowPeekContinuityKeyDown);
    CHECK(event.modifiers == 0x300u);
    now_continuity_keyboard_commit(
        &cell, &event, kNowPeekContinuityKeyErrorNone);
    CHECK(cell.key_applied_generation == 41);
    CHECK(now_continuity_keyboard_peek(&cell, 0x1234, &event)
          == kNowContinuityKeyPeekReady);
    CHECK(event.generation == 42);
    now_continuity_keyboard_commit(
        &cell, &event, kNowPeekContinuityKeyErrorPostFailed);
    CHECK(cell.key_failed_generation == 42);
    CHECK(cell.key_failures == 1);
    CHECK(now_continuity_keyboard_peek(&cell, 0x1234, &event)
          == kNowContinuityKeyPeekNone);
    return 0;
}

static int test_target_switch_discards_old_keys(void)
{
    NowPeekContinuityCell cell;
    NowContinuityKeySnapshot event;

    memset(&cell, 0, sizeof cell);
    CHECK(enqueue(&cell, 1, 0x1111, kNowPeekContinuityKeyDown)
          == kNowContinuityKeyEnqueueOK);
    CHECK(enqueue(&cell, 2, 0x2222, kNowPeekContinuityKeyDown)
          == kNowContinuityKeyEnqueueOK);
    CHECK(cell.key_flushes == 1);
    CHECK(now_continuity_keyboard_peek(&cell, 0x1111, &event)
          == kNowContinuityKeyPeekNone);
    CHECK(now_continuity_keyboard_peek(&cell, 0x2222, &event)
          == kNowContinuityKeyPeekReady);
    CHECK(event.generation == 2);
    return 0;
}

static int test_flush_and_bound(void)
{
    NowPeekContinuityCell cell;
    NowContinuityKeySnapshot event;
    int i;

    memset(&cell, 0, sizeof cell);
    for (i = 0; i < kNowPeekContinuityKeyQueueCapacity; ++i) {
        CHECK(enqueue(&cell, (NowPeekU32)i + 1u, 0x1234,
                      kNowPeekContinuityKeyDown)
              == kNowContinuityKeyEnqueueOK);
    }
    CHECK(enqueue(&cell, 99, 0x1234, kNowPeekContinuityKeyDown)
          == kNowContinuityKeyEnqueueFull);
    CHECK(cell.key_dropped == 1);
    now_continuity_keyboard_flush(&cell);
    CHECK(cell.key_target_a5 == 0);
    CHECK(now_continuity_keyboard_peek(&cell, 0x1234, &event)
          == kNowContinuityKeyPeekNone);
    CHECK(enqueue(&cell, 100, 0x1234, kNowPeekContinuityKeyRepeat)
          == kNowContinuityKeyEnqueueOK);
    CHECK(now_continuity_keyboard_peek(&cell, 0x1234, &event)
          == kNowContinuityKeyPeekReady);
    CHECK(event.generation == 100);
    return 0;
}

static int test_invalid_input_is_not_published(void)
{
    NowPeekContinuityCell cell;

    memset(&cell, 0, sizeof cell);
    CHECK(now_continuity_keyboard_enqueue(
              &cell, 1, 0x1234, 0, 1, 99, 12, 'q', 0)
          == kNowContinuityKeyEnqueueInvalid);
    CHECK(now_continuity_keyboard_enqueue(
              &cell, 1, 0x1234, 0, 1, kNowPeekContinuityKeyDown,
              128, 'q', 0)
          == kNowContinuityKeyEnqueueInvalid);
    CHECK(cell.key_write_seq == 0);
    CHECK(cell.key_enqueued == 0);
    return 0;
}

static int test_sequence_wrap_skips_reserved_zero(void)
{
    NowPeekContinuityCell cell;
    NowContinuityKeySnapshot event;

    memset(&cell, 0, sizeof cell);
    cell.key_write_seq = 0xFFFFFFFFUL;
    cell.key_read_seq = 0xFFFFFFFFUL;
    CHECK(enqueue(&cell, 1, 0x1234, kNowPeekContinuityKeyDown)
          == kNowContinuityKeyEnqueueOK);
    CHECK(cell.key_write_seq == 1);
    CHECK(now_continuity_keyboard_peek(&cell, 0x1234, &event)
          == kNowContinuityKeyPeekReady);
    CHECK(event.queue_seq == 1);
    return 0;
}

int main(void)
{
    CHECK(test_order_and_results() == 0);
    CHECK(test_target_switch_discards_old_keys() == 0);
    CHECK(test_flush_and_bound() == 0);
    CHECK(test_invalid_input_is_not_published() == 0);
    CHECK(test_sequence_wrap_skips_reserved_zero() == 0);
    puts("now_continuity_keyboard_logic_test: ok");
    return 0;
}
