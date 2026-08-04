#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "now_ext_core_logic.h"

static int failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++failures;
    }
}

int main(void)
{
    NowPeekTable table;
    NowExtAnchorDecision d;
    NowPeekU32 expected[kNowPeekIdentityWordCount] = {1, 2, 3, 4, 5};
    NowPeekU32 stamp = 0;
    int passes;
    int publishes = 0;

    memset(&table, 0, sizeof table);
    table.magic = kNowPeekTableMagic;
    table.ext_major = kNowPeekExtMajor;
    table.length = sizeof table;
    table.identity_format = kNowPeekIdentityFormatV1;
    table.identity_length = sizeof table.identity;
    memcpy(table.identity.build_fingerprint, expected, sizeof expected);
    check(now_peek_identity_matches(&table, expected),
          "exact embedded build identity matches");
    expected[4] = 6;
    check(!now_peek_identity_matches(&table, expected),
          "build identity mismatch refuses");
    expected[4] = 5;
    table.length = offsetof(NowPeekTable, identity);
    check(!now_peek_identity_matches(&table, expected),
          "old short table has no inferred identity");
    table.length = sizeof table;
    table.identity_format = 99;
    check(!now_peek_identity_matches(&table, expected),
          "unknown identity format refuses");

    memset(&table, 0, sizeof table);
    table.length = sizeof table;
    table.writer_format = kNowPeekWriterFormatV1;
    table.writer_length = sizeof table.writer;
    table.writer.session_nonce_hi = 1;
    table.writer.app_creator = kNowPeekCanonicalAppCreator;
    table.writer.app_name = kNowPeekCanonicalAppName;
    table.writer.heartbeat_ticks = 100;
    table.writer.owner_epoch = 9;
    check(now_ext_writer_lease_valid(&table, 100), "current writer accepted");
    check(now_ext_writer_lease_valid(&table, 100 + kNowPeekWriterLeaseTicks),
          "writer accepted at lease boundary");
    check(!now_ext_writer_lease_valid(
              &table, 101 + kNowPeekWriterLeaseTicks),
          "crashed writer expires");
    table.writer.app_name = 0;
    check(!now_ext_writer_lease_valid(&table, 100),
          "differently named writer is refused");

    d = now_ext_anchor_decide(100, 0, 1, 1, 0, 0);
    check(d == kNowExtAnchorChanged, "first A5 publishes immediately");
    d = now_ext_anchor_decide(101, 100, 1, 2, 1, 1);
    check(d == kNowExtAnchorChanged,
          "WindowList change publishes immediately");
    d = now_ext_anchor_decide(105, 100, 1, 1, 1, 1);
    check(d == kNowExtAnchorSkip, "unchanged target skips before six ticks");
    d = now_ext_anchor_decide(106, 100, 1, 1, 1, 1);
    check(d == kNowExtAnchorCadence,
          "unchanged target publishes at six ticks");
    d = now_ext_anchor_decide(106, 100, 0, 1, 1, 1);
    check(d == kNowExtAnchorSkip, "zero A5 never publishes");

    for (passes = 0; passes < 12; ++passes) {
        NowPeekU32 now = 100 + (NowPeekU32)passes;

        d = now_ext_anchor_decide(now, stamp, 1, 1, 1, 1);
        if (d != kNowExtAnchorSkip) {
            ++publishes;
            stamp = now;
        }
    }
    check(publishes == 2 && publishes < passes,
          "twelve event passes cause two publishes, not twelve scans");

    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
