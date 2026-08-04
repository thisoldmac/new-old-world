#ifndef NOW_PEEK_LEASE_H
#define NOW_PEEK_LEASE_H

#include "peek_table.h"

typedef enum {
    kNowPeekOwnerScene = 0,
    kNowPeekOwnerProcesses,
    kNowPeekOwnerAct,
    kNowPeekOwnerContent,
    kNowPeekOwnerCount
} NowPeekOwner;

typedef struct {
    NowPeekU32 caps;
    NowPeekU32 expiry_ticks;
    NowPeekU32 session_epoch;
} NowPeekOwnerLease;

typedef struct {
    NowPeekOwnerLease owners[kNowPeekOwnerCount];
    NowPeekU32 session_epoch;
} NowPeekLeaseSet;

void now_peek_leases_init(NowPeekLeaseSet *set, NowPeekU32 session_epoch);
void now_peek_leases_begin_session(NowPeekLeaseSet *set,
                                   NowPeekU32 session_epoch);
void now_peek_leases_claim(NowPeekLeaseSet *set, NowPeekOwner owner,
                           NowPeekU32 caps, NowPeekU32 now_ticks,
                           NowPeekU32 expiry_ticks);
void now_peek_leases_release(NowPeekLeaseSet *set, NowPeekOwner owner,
                             NowPeekU32 caps);
void now_peek_leases_disconnect(NowPeekLeaseSet *set);
NowPeekU32 now_peek_leases_union(NowPeekLeaseSet *set,
                                 NowPeekU32 now_ticks);

#endif
