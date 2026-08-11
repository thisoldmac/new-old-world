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
