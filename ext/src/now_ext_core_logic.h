#ifndef NOW_EXT_CORE_LOGIC_H
#define NOW_EXT_CORE_LOGIC_H

#include "peek_table.h"

typedef enum {
    kNowExtAnchorSkip = 0,
    kNowExtAnchorChanged,
    kNowExtAnchorCadence
} NowExtAnchorDecision;

int now_peek_identity_matches(
    const NowPeekTable *table,
    const NowPeekU32 expected[kNowPeekIdentityWordCount]);
int now_ext_writer_lease_valid(const NowPeekTable *table,
                               NowPeekU32 now_ticks);
NowExtAnchorDecision now_ext_anchor_decide(
    NowPeekU32 now_ticks, NowPeekU32 stamp_ticks,
    NowPeekU32 current_a5, NowPeekU32 current_window_list,
    NowPeekU32 prior_a5, NowPeekU32 prior_window_list);

/* How long the application may be silent before the liveness vehicle
   stands itself down. Deliberately far longer than the writer lease.

   The lease (180 ticks) may NOT gate this plane, and getting that
   backwards would break the one thing P6 exists for: the plane was built
   because a modal alert starved the application for ninety seconds while
   the machine was perfectly healthy, and an application that is starved
   cannot renew a lease. A vehicle gated on the lease would therefore
   retire itself at exactly the moment it became the only thing still
   running.

   Ten minutes instead, and the number is derived rather than picked: the
   host declares a guest gone after ~75 s of silence, so by the time this
   expires the session it protects has been over for eight minutes and
   retiring costs nothing real. What it buys is that an application which
   CRASHED without withdrawing its endpoint stops costing the machine a
   five-second interrupt forever. */
enum {
    kNowPeekLivenessIdleTicks = 36000
};

/* Whether the liveness vehicle should be priming itself right now.

   This is the whole of the plane's stand-down decision and it lives here,
   in the file a host `cc` compiles, because it is the one part of a
   resident component a native test can reach and mutate. The resident
   half performs; it decides nothing. */
int now_ext_liveness_should_run(const NowPeekTable *table,
                                NowPeekU32 now_ticks);

/* Metal safety gate for P9. This remains a function, rather than a local
   preprocessor switch in the resident, so a native test must change with any
   attempt to expose Continuity again. */
int now_ext_continuity_safe_on_hardware(void);

#endif
