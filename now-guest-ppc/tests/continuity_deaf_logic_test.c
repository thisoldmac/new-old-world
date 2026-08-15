/* The predicate that decides to rebuild a Continuity UDP endpoint that has
   stopped hearing. Every case below is a shape the metal or the retention
   rule has already produced, and the ones that must answer WAIT matter more
   than the one that must answer REBUILD: a rebuild is a close/reopen of an
   Open Transport endpoint, which is the churn that partially wedged OS 9
   twice, so this predicate's job is mostly to refuse. */
#include <stdio.h>

#include "continuity_deaf_logic.h"

#define CHECK(value) do { if (!(value)) {                                   \
    fprintf(stderr, "continuity deaf logic failed at line %d\n", __LINE__);  \
    return 1;                                                               \
} } while (0)

enum { kSilence = 300 };

static NowContinuityDeafState wedged(void)
{
    /* The 2026-08-15 PowerBook: an endpoint that had delivered 4563
       datagrams, an epoch armed well past the window with none at all, and
       no rebuild tried yet. */
    NowContinuityDeafState state;

    state.armed = 1;
    state.endpoint_bound = 1;
    state.delivered_endpoint = 4563;
    state.delivered_epoch = 0;
    state.ticks_since_arm = 600;
    state.rebuilt_this_epoch = 0;
    return state;
}

int main(void)
{
    NowContinuityDeafState state;

    CHECK(now_continuity_deaf_verdict(NULL, kSilence)
          == kNowContinuityDeafWait);

    state = wedged();
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafRebuild);

    /* Nothing is expecting datagrams: a disarmed epoch is silent on
       purpose, and rebuilding under it is churn with no complaint behind
       it. */
    state = wedged();
    state.armed = 0;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafWait);

    /* Nothing to rebuild. The arm path opens the endpoint and refuses when
       it cannot; this must not become a second, quieter opener. */
    state = wedged();
    state.endpoint_bound = 0;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafWait);

    /* A FRESH ENDPOINT THAT HAS NEVER DELIVERED IS NOT EVIDENCE OF
       DEAFNESS. Without this, the first arm of every session rebuilds five
       seconds in - a close/reopen at exactly the boundary the retention
       rule exists to avoid - and a rebuilt endpoint would qualify again
       immediately, which is a loop rather than a recovery. */
    state = wedged();
    state.delivered_endpoint = 0;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafWait);

    /* One accepted datagram proves the endpoint hears. A person who moved
       the pointer in and then let it rest for a minute is the ordinary
       case, and must never cost them their transport. */
    state = wedged();
    state.delivered_epoch = 1;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafWait);

    /* Inside the window, including the boundary tick: the host's first
       position follows an arm by a frame or two, but a busy guest can be
       later than that, and an early rebuild would throw away a datagram
       that was about to arrive. */
    state = wedged();
    state.ticks_since_arm = 0;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafWait);
    state.ticks_since_arm = kSilence - 1;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafWait);
    state.ticks_since_arm = kSilence;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafRebuild);

    /* One shot per epoch. A rebuild that did not help must degrade to the
       old silent failure, not to an endpoint reopened every five seconds
       for as long as the person keeps trying. */
    state = wedged();
    state.rebuilt_this_epoch = 1;
    CHECK(now_continuity_deaf_verdict(&state, kSilence)
          == kNowContinuityDeafWait);

    printf("continuity deaf logic: ok\n");
    return 0;
}
