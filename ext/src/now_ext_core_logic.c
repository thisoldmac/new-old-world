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

int now_ext_liveness_should_run(const NowPeekTable *table,
                                NowPeekU32 now_ticks)
{
    unsigned long need;
    NowPeekU32 silence;

    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic) {
        return 0;
    }
    /* The endpoint cell AND the OS string beside it, because
       published_endpoint() refuses V1 and reads both — a gate whose first
       act is the unsafe read is not a gate. */
    need = (unsigned long)offsetof(NowPeekTable, endpoint_os)
        + (unsigned long)sizeof table->endpoint_os;
    if (table->length < need
        || table->endpoint_format < kNowPeekLivenessFormatV2) {
        return 0;
    }
    /* Zero is an INSTRUCTION to stay off the wire, not an absence. An
       application that has never published and one that has withdrawn
       must look identical here, and both mean stop. */
    if (table->endpoint.endpoint_epoch == 0) {
        return 0;
    }
    /* The crashed-application backstop. Note what is NOT here: the
       three-second writer lease, which must never gate this plane — see
       kNowPeekLivenessIdleTicks. A writer cell that was never written at
       all leaves the endpoint to speak for itself. */
    if (table->length >= (unsigned long)offsetof(NowPeekTable, writer)
                           + (unsigned long)sizeof table->writer
        && table->writer_format == kNowPeekWriterFormatV1
        && table->writer.heartbeat_ticks != 0) {
        silence = now_ticks - table->writer.heartbeat_ticks;
        if (silence > (NowPeekU32)kNowPeekLivenessIdleTicks) {
            return 0;
        }
    }
    return 1;
}

int now_ext_continuity_safe_on_hardware(void)
{
    /* No P9 Time Manager or global jGNE service remains. The cooperative PPC
       pump enters a bounded resident state machine, then performs placement
       through its own synthetic Cursor Device. Metal acceptance is recorded
       separately from this build-time route guard. */
    return 1;
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
