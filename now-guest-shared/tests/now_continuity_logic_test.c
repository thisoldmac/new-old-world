#define NOW_PEEK_TABLE_HOST 1
#include <stdio.h>

#include "now_continuity_logic.h"

#define CHECK(value) do { if (!(value)) {                            \
    fprintf(stderr, "continuity logic failed at line %d\n", __LINE__); \
    return 1;                                                        \
} } while (0)

int main(void)
{
    CHECK(now_continuity_accept_rate(1) == 15);
    CHECK(now_continuity_accept_rate(16) == 30);
    CHECK(now_continuity_accept_rate(31) == 60);
    CHECK(now_continuity_clamp_lease(1) == 15);
    CHECK(now_continuity_clamp_lease(1000) == 600);
    CHECK(now_continuity_lease_for_state(
              kNowPeekContinuityStateArmed, 90)
          == kNowPeekContinuityArmGraceTicks);
    CHECK(now_continuity_lease_for_state(
              kNowPeekContinuityStateActive, 90) == 90);
    CHECK(now_continuity_sequence_newer(1, 0));
    CHECK(now_continuity_sequence_newer(1, 0xFFFFFFFFUL));
    CHECK(!now_continuity_sequence_newer(9, 9));
    CHECK(now_continuity_sequence_newer(0x7FFFFFFFUL, 0));
    CHECK(!now_continuity_sequence_newer(0x80000000UL, 0));
    CHECK(!now_continuity_sequence_newer(0x80000001UL, 0));

    CHECK(now_continuity_button_action(
              0, 0, 1, kNowPeekContinuityPrimaryDown)
          == kNowContinuityButtonPress);
    CHECK(now_continuity_button_action(
              1, 1, 2, 0) == kNowContinuityButtonRelease);
    CHECK(now_continuity_button_action(
              1, 1, 1, 0) == kNowContinuityButtonNothing);
    CHECK(now_continuity_button_action(
              0xFFFFFFFFUL, 0, 1, kNowPeekContinuityPrimaryDown)
          == kNowContinuityButtonPress);
    CHECK(now_continuity_button_action(
              2, 0, 1, kNowPeekContinuityPrimaryDown)
          == kNowContinuityButtonNothing);

    /* Interrupt-time release must see an up wherever it sits. Under rapid
       clicking the wire's current edge is already the next press by the
       time the bounded timer looks, and the release the machine needs is
       in the previous slot (measured 302-tick starvation, epoch 11 of the
       2026-08-13 185037 run). */
    /* Current edge is the release: prefer the newest generation. */
    CHECK(now_continuity_release_due(
              1, 1, 1, kNowPeekContinuityPrimaryDown, 2, 0) == 2);
    /* Current edge is already the NEXT press; the release hides in
       previous. This is the spam-click drag-lock case. */
    CHECK(now_continuity_release_due(
              1, 1, 2, 0, 3, kNowPeekContinuityPrimaryDown) == 2);
    /* Nothing held: no release regardless of edges. */
    CHECK(now_continuity_release_due(
              1, 0, 2, 0, 3, kNowPeekContinuityPrimaryDown) == 0);
    /* Both edges already applied: nothing due. */
    CHECK(now_continuity_release_due(
              3, 1, 2, 0, 3, kNowPeekContinuityPrimaryDown) == 0);
    /* Previous is an old up from before the applied press: not newer,
       must not release the currently-held gesture. */
    CHECK(now_continuity_release_due(
              5, 1, 4, 0, 6, kNowPeekContinuityPrimaryDown) == 0);
    /* Held with only newer presses visible: nothing to release. */
    CHECK(now_continuity_release_due(
              5, 1, 6, kNowPeekContinuityPrimaryDown,
              7, kNowPeekContinuityPrimaryDown) == 0);

    CHECK(now_continuity_exit_due(
        100, 90, 90, 1, 1, 11, 20, 0, 10, 20, 0)
        == kNowPeekContinuityExitGuestInput);
    CHECK(now_continuity_exit_due(
        100, 90, 90, 1, 1, 10, 20, 1, 10, 20, 0)
        == kNowPeekContinuityExitGuestInput);
    CHECK(now_continuity_exit_due(
        181, 90, 90, 1, 1, 10, 20, 0, 10, 20, 0)
        == kNowPeekContinuityExitLeaseExpired);
    CHECK(now_continuity_exit_due(
        180, 90, 90, 1, 1, 10, 20, 0, 10, 20, 0)
        == kNowPeekContinuityExitNone);
    CHECK(now_continuity_exit_due(
        390, 90, now_continuity_lease_for_state(
                     kNowPeekContinuityStateArmed, 90),
        1, 1, 10, 20, 0, 10, 20, 0)
        == kNowPeekContinuityExitNone);
    CHECK(now_continuity_exit_due(
        391, 90, now_continuity_lease_for_state(
                     kNowPeekContinuityStateArmed, 90),
        1, 1, 10, 20, 0, 10, 20, 0)
        == kNowPeekContinuityExitLeaseExpired);
    return 0;
}
