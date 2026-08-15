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

    check(now_ext_continuity_safe_on_hardware(),
          "PPC-pump-only Continuity candidate is enabled for qualification");

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

    /* P6's stand-down. This is the decision that keeps a Macintosh whose
       user never launches NOW indistinguishable from one without the
       extension, so the case that matters most is the FIRST one: a fully
       formed table with nothing published must say no. */
    memset(&table, 0, sizeof table);
    check(!now_ext_liveness_should_run(&table, 1000),
          "a zeroed table never runs the vehicle");
    table.magic = kNowPeekTableMagic;
    table.length = sizeof table;
    table.endpoint_format = kNowPeekLivenessFormatV2;
    check(!now_ext_liveness_should_run(&table, 1000),
          "no endpoint published: the vehicle stays down");
    table.endpoint.endpoint_epoch = 1;
    check(now_ext_liveness_should_run(&table, 1000),
          "a published endpoint starts the vehicle");
    table.endpoint.endpoint_epoch = 0;
    check(!now_ext_liveness_should_run(&table, 1000),
          "a withdrawn endpoint stands the vehicle back down");

    /* The lease must NOT gate this plane - see kNowPeekLivenessIdleTicks.
       A starved application cannot renew a lease, and starvation is the
       whole reason P6 exists, so an expired lease inside the idle window
       has to keep ticking. This pair is the guard against someone later
       "tidying" the decision by reusing the lease check one file over. */
    table.endpoint.endpoint_epoch = 1;
    table.writer_format = kNowPeekWriterFormatV1;
    table.writer_length = sizeof table.writer;
    table.writer.heartbeat_ticks = 1000;
    check(now_ext_liveness_should_run(
              &table, 1000 + kNowPeekWriterLeaseTicks * 10),
          "a starved application keeps the vehicle running");
    check(now_ext_liveness_should_run(
              &table, 1000 + kNowPeekLivenessIdleTicks),
          "the vehicle runs to the idle boundary");
    check(!now_ext_liveness_should_run(
              &table, 1001 + kNowPeekLivenessIdleTicks),
          "a crashed application stops costing an interrupt eventually");

    /* Accretion, the same way every other cell here is gated: an older
       resident is SHORTER and a reader must not infer a field it cannot
       reach. A short table with a set epoch is a table whose epoch is at
       an offset this build invented. */
    table.length = offsetof(NowPeekTable, endpoint_os);
    check(!now_ext_liveness_should_run(&table, 1000),
          "a table too short to hold the endpoint never runs");
    table.length = sizeof table;
    table.endpoint_format = kNowPeekLivenessFormatV2 - 1;
    check(!now_ext_liveness_should_run(&table, 1000),
          "a pre-V2 endpoint format never runs");

    return failures == 0 ? EXIT_SUCCESS : EXIT_FAILURE;
}
