#ifndef NOW_SEMANTIC_GUARD_H
#define NOW_SEMANTIC_GUARD_H

#include "peek_table.h"

typedef enum {
    kNowSemanticAccept = 0,
    kNowSemanticNoPlane,
    kNowSemanticBadRequest,
    kNowSemanticWrongTarget,
    kNowSemanticStale
} NowSemanticRequestVerdict;

typedef enum {
    kNowSemanticCopyOk = 0,
    kNowSemanticCopyNoPlane,
    kNowSemanticCopyInProgress,
    kNowSemanticCopyMismatch,
    kNowSemanticCopyMalformed,
    kNowSemanticCopyStale
} NowSemanticCopyVerdict;

int now_semantic_table_ready(volatile const NowPeekTable *table);
NowSemanticRequestVerdict now_semantic_request_verdict(
    volatile const NowPeekTable *table, NowPeekU32 current_a5,
    NowPeekU32 ticks);
NowSemanticCopyVerdict now_semantic_copy_response(
    volatile const NowPeekTable *table, NowPeekU32 ticks,
    NowPeekSemanticCell *out);
int now_semantic_request_pending(volatile const NowPeekTable *table,
                                 NowPeekU32 ticks);

#endif
