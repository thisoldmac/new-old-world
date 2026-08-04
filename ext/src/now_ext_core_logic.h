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

#endif
