/* Native (host-side) test for now-guest-ppc/src/core/wire_sleep.c.

   THE REGRESSION THIS PINS, watched failing on 2026-08-06 before it was
   fixed: a scene round trip against an idle connection cost an 86 ms
   median on an emulated G4 whose walk was 0 ms and whose answer was zero
   bytes. All of it was this rule. The guest's own instrument put the gap
   between Open Transport announcing data and the loop reading it at a
   48.5 ms mean and a 103 ms maximum - a uniform arrival into a ~111 ms
   loop, which is exactly what a six-tick sleep produces.

   Two of the three branches below have each already been the whole of a
   defect:

   - `bytes_announced` is the newest and the least obvious. Without it a
     notification that lands while this process is already awake finds
     WakeUpProcess with nothing to wake, and the request waits out the
     NEXT full sleep. Measured: two of eleven samples in the first wake
     run still cost 100 ms for this reason while the other nine cost
     under a millisecond.
   - the floor of 1 is not a tidy-up. Zero means WaitNextEvent returns at
     once, the application spins, and on a cooperatively scheduled
     Macintosh nothing else is scheduled - which starves the ANCHOR
     PLANE, because a process's A5 is captured when that process pumps.
     Watched 2026-08-03: the mirror opened a Finder window and then could
     not see the window it had just opened. */

#include <assert.h>
#include <stdio.h>

#include "wire_sleep.h"

static void test_idle_is_the_default_and_it_is_the_expensive_one(void)
{
    /* Six ticks is ~100 ms and is what a request waits out. The number
       is not asserted as correct - it is asserted as REACHED, so that a
       change to it is a change to this line and not a silent one. */
    assert(now_wire_sleep_ticks(0, 0, 6) == 6);
    assert(now_wire_sleep_ticks(0, 0, 1) == 1);
    assert(now_wire_sleep_ticks(0, 0, 3) == 3);
}

static void test_work_in_flight_takes_the_floor(void)
{
    assert(now_wire_sleep_ticks(1, 0, 6) == 1);
    assert(now_wire_sleep_ticks(1, 0, 60) == 1);
}

static void test_announced_bytes_take_the_floor(void)
{
    /* The wake's race, closed. Data is here and unread; there is nothing
       left to wait for, whatever the idle policy says. */
    assert(now_wire_sleep_ticks(0, 1, 6) == 1);
    assert(now_wire_sleep_ticks(0, 1, 60) == 1);
    assert(now_wire_sleep_ticks(1, 1, 6) == 1);
}

static void test_never_zero(void)
{
    /* Every route to the number, including the ones a caller should not
       be able to ask for. A zero here is not slow, it is a starved
       Macintosh and a mirror that sees one window. */
    assert(now_wire_sleep_ticks(0, 0, 0) == 1);
    assert(now_wire_sleep_ticks(0, 0, -5) == 1);
    assert(now_wire_clamp_idle(0) == 1);
    assert(now_wire_clamp_idle(-1) == 1);
}

static void test_ceiling(void)
{
    /* A second. Past it the heartbeat cannot report a dead link inside
       its own timeouts. */
    assert(now_wire_clamp_idle(61) == 60);
    assert(now_wire_clamp_idle(100000) == 60);
    assert(now_wire_sleep_ticks(0, 0, 600) == 60);
    assert(now_wire_clamp_idle(60) == 60);
}

int main(void)
{
    test_idle_is_the_default_and_it_is_the_expensive_one();
    test_work_in_flight_takes_the_floor();
    test_announced_bytes_take_the_floor();
    test_never_zero();
    test_ceiling();
    printf("wire_sleep_test: all assertions passed\n");
    return 0;
}
