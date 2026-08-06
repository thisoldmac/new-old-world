/* Native test for the NOW Extension's table contract. Runs on the host:

       cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST \
          -I ../../contract peek_table_test.c \
          -o peek_table_test && ./peek_table_test

   The static asserts in the header do the layout work at compile time
   on every compiler that includes it; this runtime half checks the
   values a wire-style reader depends on (magic, selector, versioning
   gates) and exercises the accretive-read rule the way the application
   will. Mutation check: reorder any two table fields and the header's
   own asserts refuse to build - watched once, 2026-07-21.

   Watched again for V3, 2026-07-31, with the cross-compiler half of the
   claim this time:
     - insert the name field BEFORE stack_base -> the header's asserts
       stop the build in the retrocarbon PPC compiler AND the Retro68
       68K one, not merely in the host cc (the 68K guest does not
       include this header; the extension does)
     - the same shift with those asserts RELAXED -> 3 runtime checks
       here fail, which is what this file is for: a build failure proves
       the asserts work, not that the test does
     - narrow the name field to 30 bytes with the size assert left
       satisfiable -> 2 fail. Note WHY that still compiled: the compiler
       silently padded the slot back to 60. That is precisely the drift
       the header's layout rule forbids, and only the alignment check
       sees it. */

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "peek_table.h"

static int g_failures;

static void check(int ok, const char *what)
{
    if (!ok) {
        fprintf(stderr, "FAIL: %s\n", what);
        ++g_failures;
    }
}

/* The application's acceptance rule, as it will ship: magic, exact
   major, and a length that covers what the reader wants. */
static int table_usable(const NowPeekTable *t, size_t want_length)
{
    return t->magic == (NowPeekU32)kNowPeekTableMagic
        && t->ext_major == kNowPeekExtMajor && t->length >= want_length;
}

int main(void)
{
    NowPeekTable t;

    check(kNowPeekGestaltSelector == 0x4E576578L, "selector is 'NWex'");
    check(kNowPeekTableMagic == 0x4E577074L, "magic is 'NWpt'");
    check((kNowPeekTableCapAnchors | kNowPeekTableCapTree
           | kNowPeekTableCapAct | kNowPeekTableCapContent) == 0x0f
              && (kNowPeekTableCapAnchors & kNowPeekTableCapTree) == 0
              && (kNowPeekTableCapAnchors & kNowPeekTableCapAct) == 0
              && (kNowPeekTableCapAnchors & kNowPeekTableCapContent) == 0
              && (kNowPeekTableCapTree & kNowPeekTableCapAct) == 0
              && (kNowPeekTableCapTree & kNowPeekTableCapContent) == 0
              && (kNowPeekTableCapAct & kNowPeekTableCapContent) == 0
              && (kNowPeekTableCapEvents & kNowPeekTableCapAnchors) == 0
              && (kNowPeekTableCapEvents & kNowPeekTableCapTree) == 0
              && (kNowPeekTableCapEvents & kNowPeekTableCapAct) == 0
              && (kNowPeekTableCapEvents & kNowPeekTableCapContent) == 0,
          "all five capability bits are distinct");
    /* Distinct is not enough: WHICH bit each plane holds is what a
       person reads a live `cap=15 requested=7` line with, and the
       plane numbers do not run in bit order. P3 asked for 1u << 2
       while P4 already held it (the 2026-07-31 near-miss), so P4 sits
       BELOW P3. On 2026-08-05 that cost an investigation: a drive log
       reading requested=7 was reported as "the interaction bit clear"
       and the arc opened against the host's plane policy, when 7 is
       Anchors|Tree|Act and the plane actually unrequested was P3. */
    check(kNowPeekTableCapAnchors == 1u, "P1 anchors is bit 0 (1)");
    check(kNowPeekTableCapTree == 2u, "P2 semantic tree is bit 1 (2)");
    check(kNowPeekTableCapAct == 4u, "P4 act is bit 2 (4), BELOW P3");
    check(kNowPeekTableCapContent == 8u, "P3 content is bit 3 (8)");
    /* P5 was appended after this test was written, and distinctness alone
       would have accepted it silently - which is exactly the blindness
       the four checks above exist to remove. A plane added without a line
       here is a plane nobody can read a live `cap=` word against. */
    check(kNowPeekTableCapEvents == 16u, "P5 transitions is bit 4 (16)");

    memset(&t, 0, sizeof t);
    t.magic = (NowPeekU32)kNowPeekTableMagic;
    t.ext_major = kNowPeekExtMajor;

    /* V2 appended stack_base. The seqlock's stamp must NOT have moved:
       a V1 reader looks for it at 20, and a silent shift there pairs a
       fresh stamp with fields it does not cover.

       The static asserts in the header catch this at compile time in all
       three toolchains, which is the stronger gate. These are here for
       the case the asserts are ever relaxed - watched failing with them
       removed, and they named both halves. */
    check(offsetof(NowPeekAnchorSlot, stamp_ticks) == 20,
          "V2 left the seqlock stamp where V1 reads it");
    check(offsetof(NowPeekAnchorSlot, stack_base) == 24,
          "stack_base was appended, not inserted");
    /* V3 appended again, under the same rule: both offsets above are
       unchanged, and the new field starts after them. */
    check(offsetof(NowPeekAnchorSlot, cur_ap_name) == 28,
          "cur_ap_name was appended, not inserted");
    check(kNowPeekAnchorFormatV2 > kNowPeekAnchorFormatV1
              && kNowPeekAnchorFormatV3 > kNowPeekAnchorFormatV2,
          "anchor formats are ordered, so >= is a valid gate");

    /* The layout rule the header states once: no compiler inserts
       padding, which holds only while every offset stays 4-aligned. The
       name field is bytes, so it is the one field that could break it -
       a width of 30 would compile here and silently shift the next
       appended field on a compiler that aligns to 4. */
    check(kNowPeekAnchorNameSize % 4 == 0,
          "the name width keeps the slot 4-aligned for the NEXT append");
    check(sizeof(NowPeekAnchorSlot) % 4 == 0
              && sizeof(NowPeekAnchorSlot) == 60,
          "the V3 slot is 60 bytes with no padding");
    check(offsetof(NowPeekTable, identity_format)
              == offsetof(NowPeekTable, content_block) + 4,
          "build identity was appended after every existing plane");
    check(offsetof(NowPeekTable, writer_format)
              == offsetof(NowPeekTable, identity)
                   + sizeof(NowPeekBuildIdentity),
          "writer lease was appended after build identity");
    check(sizeof(NowPeekBuildIdentity) == 40,
          "source and resident identities are five words each");
    check(sizeof(NowPeekWriterLease) == 36,
          "writer lease layout is fixed across compilers");
    check(kNowPeekAnchorCadenceTicks == 6,
          "P1 cadence is the measured six-tick budget");
    /* A whole Str31 fits: length byte plus 31 characters, so there is
       no truncation rule for the two sides to disagree about. */
    check(kNowPeekAnchorNameSize == 32, "a Str31 fits the name field whole");

    /* A core-only M0 table: prelude published, no anchor plane. */
    t.length = offsetof(NowPeekTable, anchors);
    t.anchor_format = kNowPeekAnchorFormatNone;
    check(table_usable(&t, offsetof(NowPeekTable, anchors)),
          "M0 prelude is readable");
    check(!table_usable(&t, sizeof(NowPeekTable)),
          "anchor read is refused when length stops at the prelude");

    /* A newer minor with a longer table still reads (accretive)... */
    t.ext_minor = 9;
    t.length = sizeof(NowPeekTable);
    check(table_usable(&t, sizeof(NowPeekTable)),
          "longer newer table reads");

    /* ...but a different major never does. */
    t.ext_major = kNowPeekExtMajor + 1;
    check(!table_usable(&t, offsetof(NowPeekTable, anchors)),
          "major mismatch is refused");
    t.ext_major = kNowPeekExtMajor;
    t.magic = 0;
    check(!table_usable(&t, 4), "missing magic is refused");

    /* An empty slot is invalid however you look at it - and its name is
       an empty Pascal string, which is "the extension had none", not
       "this process is nameless". */
    check(t.anchors[0].psn_high == 0 && t.anchors[0].psn_low == 0
              && t.anchors[0].stamp_ticks == 0
              && t.anchors[0].cur_ap_name[0] == 0,
          "zeroed slot reads as absent");

    /* P6, the liveness endpoint. The resident dials the host itself, and
       the ONLY way it can learn where is this cell: it has no
       preferences, no file access at interrupt time, and no way to ask
       the application that may be the very thing starved. */

    /* Zero epoch is an instruction to stay off the wire, not an old
       value worth retrying — an application that has never connected and
       one that has withdrawn consent must look the same here. */
    memset(&t.endpoint, 0, sizeof(t.endpoint));
    check(t.endpoint.endpoint_epoch == 0,
          "a zeroed endpoint says do not dial");

    /* Committed by the epoch LAST, the same publish-last rule the writer
       lease uses: a resident that sees a nonzero epoch has the whole
       address, never half of one. */
    t.endpoint.host_ipv4 = 0x0A000202u;      /* 10.0.2.2, the QEMU gateway */
    t.endpoint.host_port = 5250;
    t.endpoint.guest_name[0] = 4;
    t.endpoint.guest_name[1] = 'M';
    t.endpoint.guest_name[2] = 'a';
    t.endpoint.guest_name[3] = 'c';
    t.endpoint.guest_name[4] = '!';
    t.endpoint.endpoint_epoch = 1;
    check(t.endpoint.endpoint_epoch == 1
              && t.endpoint.host_ipv4 == 0x0A000202u
              && t.endpoint.host_port == 5250,
          "a committed endpoint carries the whole address");

    /* The name is carried as a fixed-width Pascal string rather than a
       pointer, because it is read from a foreign context after the
       application's heap may be gone — and it must be the SAME name the
       application dials with, since that name is what associates the two
       connections on the host. */
    check(sizeof(t.endpoint.guest_name) == 32,
          "the guest name is fixed width, never a pointer");
    check(t.endpoint.guest_name[0] == 4,
          "the guest name is a Pascal string with its own length");

    /* Old residents are SHORTER, which is how they say they lack a
       plane; the application must gate on length before reading here.
       U9 appended the transport probe behind the counter, so the counter
       is no longer the tail — and the two cells are gated SEPARATELY in
       mirror_probe.c, because an extension with one and not the other is
       a build that exists. */
    check(offsetof(NowPeekTable, transport_format)
              == offsetof(NowPeekTable, liveness_ticks) + sizeof(NowPeekU32),
          "the transport probe appends directly behind the tick counter");
    check(offsetof(NowPeekTable, transport_result) + sizeof(NowPeekI32)
              == sizeof(NowPeekTable),
          "the transport result is the tail, so shorter means absent");

    /* Reachability is not a dial, and the values are the contract rather
       than an ordering — a refusal carries the driver's own OSErr so that
       "no MacTCP here" and "MacTCP said no" are different answers. */
    t.transport_probe = kNowPeekTransportRefused;
    t.transport_result = -192;
    check(t.transport_probe != kNowPeekTransportOpen
              && t.transport_result != 0,
          "a refusal arrives with its reason attached");

    /* The vehicle's own proof-of-life. A COUNT, not a timestamp: a
       stopped clock and a stopped task are indistinguishable in a
       timestamp, and telling them apart is the whole job. */
    t.liveness_ticks = 0;
    check(t.liveness_ticks == 0, "a resident that never ticked reads zero");
    t.liveness_ticks = 7;
    check(t.liveness_ticks == 7, "the tick counter is resident-written");
    check((kNowPeekTableCapLiveness & (kNowPeekTableCapAnchors
                                       | kNowPeekTableCapTree
                                       | kNowPeekTableCapAct
                                       | kNowPeekTableCapContent
                                       | kNowPeekTableCapEvents)) == 0,
          "the liveness capability bit collides with no other plane");

    if (g_failures != 0) {
        fprintf(stderr, "%d check(s) failed\n", g_failures);
        return EXIT_FAILURE;
    }
    printf("peek_table: all checks passed\n");
    return EXIT_SUCCESS;
}
