#ifndef NOW_PEEK_LEASE_H
#define NOW_PEEK_LEASE_H

#include "peek_table.h"

typedef enum {
    kNowPeekOwnerScene = 0,
    kNowPeekOwnerProcesses,
    kNowPeekOwnerAct,
    kNowPeekOwnerContent,
    /* P5's reader. Its own owner rather than sharing Content's, because
       `transitions stop` must not take the content plane down with it —
       the union is what keeps a plane armed while anyone wants it, and
       two consumers behind one name is exactly the arrangement the
       comment in peek.h was written about. */
    kNowPeekOwnerEvents,
    /* The reference layer's walk. Its own owner and NOT the scene's,
       because a headless caller that never asks for a scene must still
       be able to observe: the scene owner's claim is only renewed once
       a `scene.request` has been served on the link, so an MCP client
       driving `elements` alone inherited a plane nobody had claimed and
       was told every foreign process was unreachable. Sharing Act's
       would be worse — an act releases on shutdown and would take the
       observation's plane with it. */
    kNowPeekOwnerObserve,
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
