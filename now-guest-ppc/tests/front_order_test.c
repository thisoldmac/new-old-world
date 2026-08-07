/* Native test for the cross-application layer ledger. Runs on the host:

       cc -Wall -Wextra -Werror -I ../src front_order_test.c \
          ../src/scene/front_order.c -o front_order_test && ./front_order_test

   The interesting half is the last block: it replays the EXACT fronting
   sequence of the 019 integration capture run and requires the table to
   produce the layering the guest's own screendump shows. That run is on
   disk (~/Lab/Assets/now-mirror-assets/019-integration/), the sequence
   is in its manifest.json, and the picture that disagrees with today's
   scene order is date-and-time-guest.png. */

#include <stdio.h>
#include <string.h>

#include "scene/front_order.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* The four PSNs of the 019 run, as the scenes report them. */
enum {
    kNow  = 29360131UL,
    kFind = 29949953UL,
    kTime = 35520514UL,
    kAppe = 35979265UL
};

int main(void)
{
    NowFrontOrder o;
    int i;

    now_front_order_reset(&o);

    /* NOTHING IS KNOWN UNTIL SOMETHING IS WATCHED. A fresh table must
       not rank anybody: a scene collected in NOW's first moments has to
       say the cross-application order is unknown, not assert one. */
    check(now_front_order_seq(&o, 0, kFind) == 0, "fresh table ranks nobody");
    check(now_front_order_known_count(&o) == 0, "fresh table is empty");

    /* A transition is recorded once. */
    check(now_front_order_note(&o, 0, kNow) == 1, "first front is a change");
    check(now_front_order_note(&o, 0, kNow) == 0, "same front is not");
    check(now_front_order_note(&o, 0, kNow) == 0, "still not, on any pass");
    check(now_front_order_seq(&o, 0, kNow) == 1, "and burned one number");

    /* IDLE PASSES MUST NOT AGE THE TABLE. An event loop calls this many
       times a second; if a repeat consumed a sequence number the gap
       between two applications would grow without either of them
       moving, and eviction would eventually throw away a process that
       is on screen. */
    check(now_front_order_note(&o, 0, kFind) == 1, "Finder comes forward");
    for (i = 0; i < 500; ++i) {
        now_front_order_note(&o, 0, kFind);
    }
    check(now_front_order_seq(&o, 0, kFind) == 2, "500 idle passes cost 0");
    check(now_front_order_seq(&o, 0, kNow) == 1, "and left NOW where it was");

    /* Re-fronting moves a process to the top without adding a slot. */
    check(now_front_order_note(&o, 0, kNow) == 1, "NOW comes back");
    check(now_front_order_seq(&o, 0, kNow) > now_front_order_seq(&o, 0, kFind),
          "and is now in front of the Finder");
    check(now_front_order_known_count(&o) == 2, "with no new slot");

    /* The Process Manager's "no process" is not a process. */
    check(now_front_order_note(&o, 0, 0) == 0, "PSN 0/0 is not recorded");
    check(now_front_order_seq(&o, 0, 0) == 0, "and cannot be ranked");

    /* THE CAPTURED RUN. manifest.json's targets, in order: New Old
       World, Finder, Finder, Date & Time, Appearance. At the
       `date-and-time` capture the guest's screendump shows Date & Time
       in front, the Finder's "Macintosh HD" window behind it, and NOW's
       window behind that - and today's scene emits NOW ahead of the
       Finder, which is the defect. */
    now_front_order_reset(&o);
    now_front_order_note(&o, 0, kNow);
    now_front_order_note(&o, 0, kFind);
    now_front_order_note(&o, 0, kFind);   /* two Finder targets in a row */
    now_front_order_note(&o, 0, kTime);
    check(now_front_order_seq(&o, 0, kTime)
              > now_front_order_seq(&o, 0, kFind),
          "Date & Time is in front of the Finder");
    check(now_front_order_seq(&o, 0, kFind)
              > now_front_order_seq(&o, 0, kNow),
          "the Finder is in front of New Old World "
          "(the render drew this pair the wrong way round)");

    now_front_order_note(&o, 0, kAppe);
    check(now_front_order_seq(&o, 0, kAppe)
              > now_front_order_seq(&o, 0, kTime),
          "Appearance is in front of Date & Time");

    /* A process nobody has seen fronted stays unranked, and the caller
       is obliged to say so rather than place it. */
    check(now_front_order_seq(&o, 0, 30736386UL) == 0,
          "tbt-worker was never fronted and has no rank");

    /* EVICTION FORGETS THE BACK, NOT THE FRONT, and admits it. */
    now_front_order_reset(&o);
    for (i = 0; i < kNowFrontOrderSlots + 4; ++i) {
        now_front_order_note(&o, 0, (unsigned long)(1000 + i));
    }
    check(now_front_order_known_count(&o) == kNowFrontOrderSlots,
          "the table stays bounded");
    check(o.evictions == 4, "and counts what it had to forget");
    check(now_front_order_seq(&o, 0, 1000) == 0, "the oldest is gone");
    check(now_front_order_seq(&o, 0,
                              (unsigned long)(1000 + kNowFrontOrderSlots + 3))
              != 0, "the newest is kept");

    if (g_failures != 0) {
        fprintf(stderr, "%d failure(s)\n", g_failures);
        return 1;
    }
    printf("front_order_test: ok\n");
    return 0;
}
