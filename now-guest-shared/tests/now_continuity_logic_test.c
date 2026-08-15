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

    /* Finder pairs clicks against a private copy of the double-click
       time, not the live global: a pair 56 ticks apart failed under an
       active 60-tick window while SimpleText accepted the same stream
       (2026-08-13 210811, app=Find/app=Simp). The rewrite compresses
       synthetic mouse-event `when`s so ANY consumer's arithmetic pairs
       them, without changing which events exist. */
    /* Inside the window: rewritten to previous + spacing. */
    CHECK(now_continuity_when_rewrite(1000, 1041, 60, 4) == 1004);
    /* Outside the window: no rewrite, chain resets on the caller. */
    CHECK(now_continuity_when_rewrite(1000, 1061, 60, 4) == 0);
    /* Real spacing already tighter than the target: keep the original -
       never move an event's when forward in time. */
    CHECK(now_continuity_when_rewrite(1000, 1002, 60, 4) == 0);
    /* First event of a chain (no previous): no rewrite. */
    CHECK(now_continuity_when_rewrite(0, 1041, 60, 4) == 0);

    /* The exposure barrier. The case it exists for is the 2026-08-15 metal
       drop: the release rode a settled point of 274,311 while the guest's
       mouse global still read the crossing point 0,362. */
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 0, 362, 0, 4)
          == kNowContinuityBarrierWait);
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 0, 362, 3, 4)
          == kNowContinuityBarrierWait);
    /* Deadline reached: apply and say so, because an edge held forever is a
       stuck drag - strictly worse than an edge at a stale point. */
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 0, 362, 4, 4)
          == kNowContinuityBarrierExpired);
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 0, 362, 99, 4)
          == kNowContinuityBarrierExpired);
    /* Exposed: the global caught up, whatever the clock says. */
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 274, 311, 0, 4)
          == kNowContinuityBarrierExposed);
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 274, 311, 99, 4)
          == kNowContinuityBarrierExposed);
    /* One axis is enough to be behind. */
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 274, 362, 0, 4)
          == kNowContinuityBarrierWait);
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 0, 311, 0, 4)
          == kNowContinuityBarrierWait);
    /* Negative coordinates compare as coordinates, not as magnitudes. */
    CHECK(now_continuity_button_barrier(1, 1, -8, -8, -8, -8, 0, 4)
          == kNowContinuityBarrierExposed);
    CHECK(now_continuity_button_barrier(1, 1, -8, -8, 8, 8, 0, 4)
          == kNowContinuityBarrierWait);
    /* Nothing to wait FOR is not something to wait for: an unaskable
       instrument must never become a hang. */
    CHECK(now_continuity_button_barrier(0, 1, 274, 311, 0, 362, 0, 4)
          == kNowContinuityBarrierExposed);
    CHECK(now_continuity_button_barrier(1, 0, 274, 311, 0, 362, 0, 4)
          == kNowContinuityBarrierExposed);
    CHECK(now_continuity_button_barrier(0, 0, 274, 311, 0, 362, 0, 4)
          == kNowContinuityBarrierExposed);
    /* A zero deadline is a barrier that is switched off, and says so with
       `expired` rather than pretending the point was exposed. */
    CHECK(now_continuity_button_barrier(1, 1, 274, 311, 0, 362, 0, 0)
          == kNowContinuityBarrierExpired);

    /* The asymmetric bounds themselves (2026-08-15 metal: PowerBook 1400c
       routinely exceeded the old shared 4-tick bound on release edges).
       Press stays tight for feel; release gets a generous 0.5s bound
       because what is at stake there is a real file's location. Pinned as
       values, not just as "release > press", because a caller wiring the
       wrong constant to the wrong edge compiles fine and only shows up as
       a stale-point relocation on metal. */
    CHECK(kNowContinuityExposureDeadlineTicksPress == 4);
    CHECK(kNowContinuityExposureDeadlineTicksRelease == 30);
    CHECK(kNowContinuityExposureDeadlineTicksRelease
          > kNowContinuityExposureDeadlineTicksPress);
    /* The exact release-edge failure from the 2026-08-15 metal round:
       `gen=282 down=0 applied=18,111 exposed=74,146 via=record waited=4
       expired` - a release beat the propagation by 60px at the old shared
       4-tick bound. Same wait must now still be WAITing under the release
       deadline; the old press-sized bound would still expire it, which is
       exactly why press and release may not share one constant. */
    CHECK(now_continuity_button_barrier(
              1, 1, 18, 111, 74, 146, 4,
              kNowContinuityExposureDeadlineTicksRelease)
          == kNowContinuityBarrierWait);
    CHECK(now_continuity_button_barrier(
              1, 1, 18, 111, 74, 146, 4,
              kNowContinuityExposureDeadlineTicksPress)
          == kNowContinuityBarrierExpired);

    /* Settling the edge's own point before the edge. The 2026-08-15 17:19:06
       metal line is the case: the epoch had already EXITED (disarmed) when
       the release was served, so the ordinary active-only apply declined and
       this side's last applied point was 501,446 - an early drag point the
       target's own drag loop starved us at - while the edge rode the host's
       settled origin 504,451. Without this the barrier holds against 501,446
       and burns its whole 30-tick bound. */
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitDisarmed, 1, 1, 1,
              504, 451, 501, 446) == 1);
    /* Already there: no manager traffic for a point the pointer holds. This
       is the ordinary active round, where the apply above ran first. */
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitNone, 1, 1, 1,
              504, 451, 504, 451) == 0);
    /* One axis is enough to be elsewhere. */
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitNone, 1, 1, 1,
              504, 451, 504, 446) == 1);
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitNone, 1, 1, 1,
              504, 451, 501, 451) == 1);
    /* Nothing applied yet: the edge's point is the only one there is. */
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitNone, 1, 1, 0,
              504, 451, 0, 0) == 1);
    /* No edge pending, or no position this epoch ever carried: the cell's
       point is then a previous epoch's and moving to it is a teleport. */
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitNone, 0, 1, 1,
              504, 451, 501, 446) == 0);
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitNone, 1, 0, 1,
              504, 451, 501, 446) == 0);
    /* Never against the human's own hand: a guest-input exit means somebody
       touched the trackpad, and tidying the release would take the machine
       off them. */
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitGuestInput, 1, 1, 1,
              504, 451, 501, 446) == 0);
    /* A lease death or host-left still settles: nobody else has the pointer,
       and the edge is about to be dispatched wherever it sits. */
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitLeaseExpired, 1, 1, 1,
              504, 451, 501, 446) == 1);
    CHECK(now_continuity_settle_before_edge(
              (NowPeekU32)kNowPeekContinuityExitHostLeft, 1, 1, 1,
              504, 451, 501, 446) == 1);

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
