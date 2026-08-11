#include "peek_lease.h"

#include <string.h>

static int valid_owner(NowPeekOwner owner)
{
    return (int)owner >= 0 && (int)owner < (int)kNowPeekOwnerCount;
}

static int tick_after(NowPeekU32 a, NowPeekU32 b)
{
    return (NowPeekI32)(a - b) > 0;
}

void now_peek_leases_init(NowPeekLeaseSet *set, NowPeekU32 session_epoch)
{
    memset(set, 0, sizeof *set);
    set->session_epoch = session_epoch;
}

void now_peek_leases_begin_session(NowPeekLeaseSet *set,
                                   NowPeekU32 session_epoch)
{
    now_peek_leases_init(set, session_epoch);
}

void now_peek_leases_claim(NowPeekLeaseSet *set, NowPeekOwner owner,
                           NowPeekU32 caps, NowPeekU32 now_ticks,
                           NowPeekU32 expiry_ticks)
{
    NowPeekOwnerLease *lease;

    (void)now_ticks;
    if (set == NULL || !valid_owner(owner) || expiry_ticks == 0) {
        return;
    }
    lease = &set->owners[owner];
    lease->caps |= caps;
    lease->expiry_ticks = expiry_ticks;
    lease->session_epoch = set->session_epoch;
}

void now_peek_leases_release(NowPeekLeaseSet *set, NowPeekOwner owner,
                             NowPeekU32 caps)
{
    NowPeekOwnerLease *lease;

    if (set == NULL || !valid_owner(owner)) {
        return;
    }
    lease = &set->owners[owner];
    lease->caps &= ~caps;
    if (lease->caps == 0) {
        lease->expiry_ticks = 0;
    }
}

void now_peek_leases_disconnect(NowPeekLeaseSet *set)
{
    if (set != NULL) {
        memset(set->owners, 0, sizeof set->owners);
    }
}

NowPeekU32 now_peek_leases_union(NowPeekLeaseSet *set,
                                 NowPeekU32 now_ticks)
{
    NowPeekU32 wanted = 0;
    int i;

    if (set == NULL) {
        return 0;
    }
    for (i = 0; i < (int)kNowPeekOwnerCount; ++i) {
        NowPeekOwnerLease *lease = &set->owners[i];

        if (lease->session_epoch != set->session_epoch
            || lease->expiry_ticks == 0
            || tick_after(now_ticks, lease->expiry_ticks)) {
            lease->caps = 0;
            lease->expiry_ticks = 0;
            continue;
        }
        wanted |= lease->caps;
    }
    return wanted;
}
