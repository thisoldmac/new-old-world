/*
 * P5's decisions, run with the host compiler.
 *
 * The filter these belong to cannot be run off a Macintosh, so what can
 * be decided without the Toolbox is decided in now_event_logic.c and
 * proven here. Every case below is a rule the plane would otherwise
 * only be able to state.
 */
#include <stdio.h>
#include <string.h>

#include "now_event_logic.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

int main(void)
{
    NowEventArm arm;
    NowEventWatched now, last;
    NowEventU32 value, previous, drops;
    int slot;

    /* ---- arming is fail-closed in every direction ---- */
    memset(&arm, 0, sizeof arm);
    arm.target_a5 = 0x1000;
    arm.expiry = 5000;
    arm.commit = 1;
    check(now_event_should_record(&arm, 4000, 0x1000) == 1,
          "an armed, unexpired request for the pumping world records");
    check(now_event_should_record(&arm, 4000, 0x2000) == 0,
          "another A5 world is not this request's target");
    check(now_event_should_record(&arm, 6000, 0x1000) == 0,
          "an expired deadline stops recording");
    check(now_event_should_record(&arm, 4000, 0) == 0,
          "no A5 world at all records nothing");

    /* Naming NO target must name NOTHING. The obvious reading of a bare
       arm is "instrument everything", and that is the reading
       docs/resident-components.md forbids.

       Watched under mutation 2026-08-05: this assertion survives removing
       the `target_a5 == 0` clause, because the target-mismatch check
       below it already enforces the property. It fails, correctly, when
       that mismatch check is removed. The property is proven; the clause
       that appears to protect it is not the one that does. */
    arm.target_a5 = 0;
    check(now_event_should_record(&arm, 4000, 0x1000) == 0,
          "a request naming no target instruments nothing");
    arm.target_a5 = 0x1000;

    arm.commit = 0;
    check(now_event_should_record(&arm, 4000, 0x1000) == 0,
          "an uncommitted request is not a request");
    arm.commit = 1;

    /* The expiry exists so a caller that dies leaves no hook armed; 0
       must therefore read as expired-on-sight rather than as forever. */
    arm.expiry = 0;
    check(now_event_should_record(&arm, 1, 0x1000) == 0,
          "a zero expiry is expired on sight, never eternal");

    /* ---- which transition this pass owes ---- */
    memset(&now, 0, sizeof now);
    memset(&last, 0, sizeof last);
    now.a5 = last.a5 = 0x1000;
    now.window_list = last.window_list = 0x2000;
    now.menu_list = last.menu_list = 0x3000;
    check(now_event_kind_for(&now, &last, 100, 100, 0) == 0,
          "nothing changed and no cadence is owed: no record");

    now.window_list = 0x2100;
    check(now_event_kind_for(&now, &last, 100, 100, 0)
              == kNowEventKindWindowList,
          "a moved window list is the window-list transition");
    now_event_values_for(kNowEventKindWindowList, &now, &last,
                         &value, &previous);
    check(value == 0x2100 && previous == 0x2000,
          "the record carries both values so a reader needs no memory");

    /* A5 outranks the rest: when the pumping world changes, every other
       watched word belongs to a different process and comparing them
       would report a transition that never happened. */
    now.a5 = 0x9000;
    check(now_event_kind_for(&now, &last, 100, 100, 0)
              == kNowEventKindFrontProcess,
          "a changed A5 world outranks its own window list");
    now.a5 = last.a5;
    now.window_list = last.window_list;

    now.menu_list = 0x3300;
    check(now_event_kind_for(&now, &last, 100, 100, 0)
              == kNowEventKindMenuList,
          "a changed menu list is its own transition");
    now.menu_list = last.menu_list;

    /* Cadence is last and only when asked for: a heartbeat exists so a
       reader can tell a quiet machine from a stopped one. */
    check(now_event_kind_for(&now, &last, 200, 100, 60)
              == kNowEventKindHeartbeat,
          "cadence elapsed with nothing changed gives a heartbeat");
    check(now_event_kind_for(&now, &last, 200, 100, 0) == 0,
          "cadence 0 disables the heartbeat rather than firing always");
    check(now_event_kind_for(&now, &last, 120, 100, 60) == 0,
          "cadence not yet elapsed owes nothing");

    /* ---- the ring, and the honesty of its overflow ---- */
    slot = now_event_slot_for(0, 0, 256, &drops);
    check(slot == 0 && drops == 0, "the first record lands at slot 0");
    slot = now_event_slot_for(257, 255, 256, &drops);
    check(slot == 1, "the cursor wraps by modulo");

    /* Overflow is NORMAL here - the reader is a wire round trip behind -
       so the only unacceptable outcome is an unadmitted one. */
    slot = now_event_slot_for(300, 40, 256, &drops);
    check(drops == 1, "a reader more than a ring behind is told it lost");
    slot = now_event_slot_for(300, 45, 256, &drops);
    check(drops == 0, "a reader inside the ring loses nothing");

    slot = now_event_slot_for(0, 0, 0, &drops);
    check(slot == -1 && drops == 1,
          "a ring with no records refuses rather than dividing by zero");

    if (failures == 0) {
        printf("now_event_logic_test ok\n");
    }
    return failures == 0 ? 0 : 1;
}
