#include "now_ext_core_logic.h"

#include <string.h>

int now_peek_identity_matches(
    const NowPeekTable *table,
    const NowPeekU32 expected[kNowPeekIdentityWordCount])
{
    unsigned long need;

    if (table == NULL || expected == NULL) {
        return 0;
    }
    need = (unsigned long)offsetof(NowPeekTable, identity)
        + (unsigned long)sizeof table->identity;
    return table->magic == (NowPeekU32)kNowPeekTableMagic
        && table->ext_major == kNowPeekExtMajor
        && table->length >= need
        && table->identity_format == kNowPeekIdentityFormatV1
        && table->identity_length == sizeof table->identity
        && memcmp(table->identity.build_fingerprint, expected,
                  sizeof table->identity.build_fingerprint) == 0;
}

int now_ext_writer_lease_valid(const NowPeekTable *table,
                               NowPeekU32 now_ticks)
{
    unsigned long need;
    NowPeekU32 age;

    if (table == NULL) {
        return 0;
    }
    need = (unsigned long)offsetof(NowPeekTable, writer)
        + (unsigned long)sizeof table->writer;
    if (table->length < need
        || table->writer_format != kNowPeekWriterFormatV1
        || table->writer_length != sizeof table->writer
        || (table->writer.session_nonce_hi == 0
            && table->writer.session_nonce_lo == 0)
        || table->writer.app_creator != kNowPeekCanonicalAppCreator
        || table->writer.app_name != kNowPeekCanonicalAppName
        || table->writer.heartbeat_ticks == 0) {
        return 0;
    }
    age = now_ticks - table->writer.heartbeat_ticks;
    return age <= (NowPeekU32)kNowPeekWriterLeaseTicks;
}

NowExtAnchorDecision now_ext_anchor_decide(
    NowPeekU32 now_ticks, NowPeekU32 stamp_ticks,
    NowPeekU32 current_a5, NowPeekU32 current_window_list,
    NowPeekU32 prior_a5, NowPeekU32 prior_window_list)
{
    if (current_a5 == 0) {
        return kNowExtAnchorSkip;
    }
    if (stamp_ticks == 0 || current_a5 != prior_a5
        || current_window_list != prior_window_list) {
        return kNowExtAnchorChanged;
    }
    if (now_ticks - stamp_ticks >= (NowPeekU32)kNowPeekAnchorCadenceTicks) {
        return kNowExtAnchorCadence;
    }
    return kNowExtAnchorSkip;
}
