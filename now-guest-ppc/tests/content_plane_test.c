/*
 * content_plane_test.c - the content plane's decisions, on a host cc.
 *
 *   cc -Wall -Wextra -Werror -DNOW_PEEK_TABLE_HOST -I contract \
 *      -I ext/src now-guest-ppc/tests/content_plane_test.c \
 *      ext/src/now_content_logic.c -o /tmp/t && /tmp/t
 *
 * (scripts/test-native runs exactly that; the line is here because every
 * test in this tree carries its own.)
 *
 * WHAT THIS COVERS AND WHAT IT CANNOT. The plane's hooks run at draw time
 * inside another process, and nothing short of a Macintosh executes them.
 * What a host CAN execute is every decision that precedes a hook: whether
 * to arm at all, where a record lands, and what changed. Those are in
 * ext/src/now_content_logic.c for that reason - the peek_oracle.c split.
 *
 * NOT covered here, and not covered anywhere yet: installing a CQDProcs on
 * a live port, the re-entrancy guard, tail-calling the standard procs, and
 * the WindowList walk. Those are now_content.c and they are Toolbox to the
 * last line.
 *
 * The arm cases are the ones to read first. The plane's whole safety story
 * is that a request which does not name its target instruments NOTHING,
 * and a test suite that only checked the happy path would pass with that
 * property removed.
 */

#include "content_table.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failures;

static void check(int cond, const char *what)
{
    if (!cond) {
        printf("FAIL %s\n", what);
        failures++;
    }
}

static void check_eq(long got, long want, const char *what)
{
    if (got != want) {
        printf("FAIL %s: got %ld want %ld\n", what, got, want);
        failures++;
    }
}

/* ---- arming ---------------------------------------------------------- */

static NowContentRequest good_request(void)
{
    NowContentRequest r;

    r.plane_bits = (NowContentU32)kNowPeekTableCapContent;
    r.arm_commit = (NowContentU32)kNowContentArmCommit;
    r.arm_a5 = 0x00123456u;
    r.arm_expiry = 5000u;
    r.mode = (NowContentU32)kNowContentModeRecord;
    r.arm_window = 0x00ABCDEFu;
    r.arm_psn_hi = 0;
    r.arm_psn_lo = 42;
    r.arm_generation = 7;
    return r;
}

static NowContentLifecycleFacts live_lifecycle(void)
{
    NowContentLifecycleFacts f;

    memset(&f, 0, sizeof f);
    f.verdict = kNowContentVerdictArmed;
    f.current_a5 = 0x1000u;
    f.request_window = 0x2000u;
    f.request_generation = 9u;
    f.window_live = 1;
    return f;
}

static void test_lifecycle_exact_window_and_redraw(void)
{
    NowContentLifecycleFacts f = live_lifecycle();
    NowContentU32 actions = now_content_lifecycle_decide(&f);

    check((actions & kNowContentLifeInstall) != 0,
          "a live exact window installs");
    check((actions & kNowContentLifeInvalidate) != 0,
          "a new exact window requests one invalidation");
    f.has_slot = 1;
    f.slot_a5 = f.current_a5;
    f.slot_window = f.request_window;
    f.slot_generation = f.request_generation;
    f.redraw_requested = 1;
    actions = now_content_lifecycle_decide(&f);
    check_eq((long)actions, 0,
             "a stable installed generation neither reinstalls nor redraws");
}

static void test_lifecycle_close_relaunch_and_retarget(void)
{
    NowContentLifecycleFacts f = live_lifecycle();
    NowContentU32 actions;

    f.has_slot = 1;
    f.slot_a5 = f.current_a5;
    f.slot_window = f.request_window;
    f.slot_generation = f.request_generation;
    f.window_live = 0;
    actions = now_content_lifecycle_decide(&f);
    check((actions & kNowContentLifeForget) != 0,
          "window disposal forgets without dereferencing the stale port");
    check((actions & kNowContentLifeRestore) == 0,
          "window disposal never restores through a dead port");

    f = live_lifecycle();
    f.has_slot = 1;
    f.slot_a5 = f.current_a5;
    f.slot_window = 0x3000u;
    f.slot_generation = 8u;
    f.hook_owned = 1;
    actions = now_content_lifecycle_decide(&f);
    check((actions & kNowContentLifeRestore) != 0,
          "relaunch or retarget restores an owned live old hook");
    check((actions & kNowContentLifeInstall) != 0,
          "relaunch or retarget installs only the new exact identity");
}

static void test_lifecycle_disarm_expiry_death_and_suspension(void)
{
    NowContentLifecycleFacts f = live_lifecycle();
    NowContentU32 actions;

    f.has_slot = 1;
    f.slot_a5 = f.current_a5;
    f.slot_window = f.request_window;
    f.slot_generation = f.request_generation;
    f.hook_owned = 1;
    f.verdict = kNowContentVerdictIdle;
    actions = now_content_lifecycle_decide(&f);
    check((actions & (kNowContentLifeRestore | kNowContentLifeForget))
              == (kNowContentLifeRestore | kNowContentLifeForget),
          "disarm restores only an owned live hook then forgets it");

    f.verdict = kNowContentVerdictExpired;
    actions = now_content_lifecycle_decide(&f);
    check((actions & kNowContentLifeRetire) != 0,
          "lease expiry retires even when observed outside the target");

    f.current_a5 = 0x9999u;
    actions = now_content_lifecycle_decide(&f);
    check((actions & (kNowContentLifeRestore | kNowContentLifeForget)) == 0,
          "death or suspension is not cleaned through a foreign context");
}

static void test_arm_happy_path(void)
{
    NowContentRequest r = good_request();

    check_eq(now_content_arm_verdict(&r, 0x00123456u, 4999u),
             kNowContentVerdictArmed, "named target inside deadline arms");
    r.mode = (NowContentU32)kNowContentModeCount;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictArmed, "count mode arms too");
}

/* THE case. A commit word with no target must instrument nothing. The
   obvious reading of a bare arm is "everything"; a sibling spike measured
   what that costs (docs/resident-components.md, P3 amendment). */
static void test_arm_without_a_target_refuses(void)
{
    NowContentRequest r = good_request();

    r.arm_a5 = 0;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictNoTarget, "no target named is a refusal");
    /* And it stays a refusal from EVERY context, which is the property -
       an unscoped request must not become armed merely by being read
       somewhere. */
    check_eq(now_content_arm_verdict(&r, 0u, 1u),
             kNowContentVerdictNoTarget, "no target, no A5 world either");
    check_eq(now_content_arm_verdict(&r, 0xDEADBEEFu, 1u),
             kNowContentVerdictNoTarget, "no target, unrelated context");
}

static void test_arm_wrong_context_refuses(void)
{
    NowContentRequest r = good_request();

    check_eq(now_content_arm_verdict(&r, 0x00999999u, 1u),
             kNowContentVerdictOtherContext, "a different A5 world refuses");
    /* A context with no A5 world at all is not the target either. */
    check_eq(now_content_arm_verdict(&r, 0u, 1u),
             kNowContentVerdictOtherContext, "no A5 world refuses");
}

static void test_arm_commit_word_is_required(void)
{
    NowContentRequest r = good_request();

    r.arm_commit = 0;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "a zeroed block is not armed");
    /* The reason the commit word is not 1: a stale or scribbled block must
       not read as a permission. */
    r.arm_commit = 1u;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "a bare 1 is not the commit word");
    r.arm_commit = 0xFFFFFFFFu;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "all-ones is not the commit word");
}

static void test_arm_plane_bit_gates_everything(void)
{
    NowContentRequest r = good_request();

    r.plane_bits = 0;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "plane bit clear means idle");
    /* Another plane's bit is not this plane's bit. */
    r.plane_bits = (NowContentU32)kNowPeekTableCapAnchors;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "the anchor bit does not arm content");
}

static void test_arm_mode_is_fail_closed(void)
{
    NowContentRequest r = good_request();

    r.mode = (NowContentU32)kNowContentModeOff;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "mode off does not arm");
    r.mode = 4u;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "an unknown mode does not arm");
    r.mode = 0xFFFFFFFFu;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictIdle, "a garbage mode does not arm");
}

/* Probe mode is a real mode: it arms on its named target and refuses
   everywhere count and record refuse. It used to be the first unknown
   value (3) in the fail-closed test above, which is exactly the compat
   story: an older extension reads it as unrecognised and stays idle. */
static void test_arm_probe_mode(void)
{
    NowContentRequest r = good_request();

    r.mode = (NowContentU32)kNowContentModeProbe;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictArmed, "probe mode arms its named target");
    check_eq(now_content_arm_verdict(&r, 0x00999999u, 1u),
             kNowContentVerdictOtherContext,
             "probe mode refuses a foreign context like any other");
    r.arm_a5 = 0;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictNoTarget,
             "probe mode without a target instruments nothing");
}

/* The probe's port match: what earns a grafProcs write after a linear
   zone scan. Every refusal here is a heap block the probe must not
   touch. */
static void test_probe_match(void)
{
    check(now_content_probe_match(0x00445566u, 0xC000u,
                                  0, 0, 404, 203,
                                  0x00445566u, 0, 0, 404, 203),
          "the owning port matches on handle, version and rect");
    check(!now_content_probe_match(0x00445568u, 0xC000u,
                                   0, 0, 404, 203,
                                   0x00445566u, 0, 0, 404, 203),
          "a different handle is a different pixmap");
    check(!now_content_probe_match(0u, 0xC000u,
                                   0, 0, 404, 203,
                                   0u, 0, 0, 404, 203),
          "a zero handle never matches, even a zeroed candidate");
    check(!now_content_probe_match(0x00445566u, 0x0000u,
                                   0, 0, 404, 203,
                                   0x00445566u, 0, 0, 404, 203),
          "a block without the CGrafPort discriminator is not a port");
    check(!now_content_probe_match(0x00445566u, 0x8000u,
                                   0, 0, 404, 203,
                                   0x00445566u, 0, 0, 404, 203),
          "half the discriminator is not the discriminator");
    check(now_content_probe_match(0x00445566u, 0xC001u,
                                  0, 0, 404, 203,
                                  0x00445566u, 0, 0, 404, 203),
          "low version bits vary and are not the test");
    check(!now_content_probe_match(0x00445566u, 0xC000u,
                                   0, 0, 404, 202,
                                   0x00445566u, 0, 0, 404, 203),
          "a stale copy of the handle without the rect is refused");
    check(!now_content_probe_match(0x00445566u, 0xC000u,
                                   0, 0, 0, 0,
                                   0x00445566u, 0, 0, 0, 0),
          "a zero-area pixmap matches nothing - a GWorld has extent");
    check(!now_content_probe_match(0x00445566u, 0xC000u,
                                   10, 10, 10, 40,
                                   0x00445566u, 10, 10, 10, 40),
          "an empty-width rect is refused the same way");
}

/* The deref route, which the OS 9 Finder made necessary: its composite
   blit's source PixMap does not RecoverHandle, so the chase matches by
   what a candidate port's own pixmap points at. Weaker key, so more
   agreement demanded - every refusal here is a heap block that happens
   to share one property with the sighted pixmap. */
static void test_probe_pixmap_match(void)
{
    check(now_content_probe_pixmap_match(0xC000u, 0, 0, 404, 218,
                                         0x00801000u, 0x8660u,
                                         0, 0, 404, 218,
                                         0x00801000u, 0x8660u,
                                         0, 0, 404, 218),
          "same base, rowBytes, port rect and pixmap bounds match");
    check(now_content_probe_pixmap_match(0xC000u, 0, 0, 404, 218,
                                         0x00801000u, 0x0660u,
                                         0, 0, 404, 218,
                                         0x00999999u, 0x8660u,
                                         0, 0, 404, 218),
          "rowBytes flags are masked, and a MOVED baseAddr still matches");
    check(!now_content_probe_pixmap_match(0xC000u, 0, 0, 404, 218,
                                          0x00801000u, 0x8661u,
                                          0, 0, 404, 218,
                                          0x00801000u, 0x8660u,
                                          0, 0, 404, 218),
          "different real rowBytes is a different pixmap");
    /* baseAddr stopped being decisive when LockPixels was measured
       relocating the record: a zero base no longer refuses on its own,
       because shape is what survives the move. The rect and rowBytes
       tests below carry the whole burden now. */
    check(now_content_probe_pixmap_match(0xC000u, 0, 0, 404, 218,
                                         0u, 0x8660u,
                                         0, 0, 404, 218,
                                         0u, 0x8660u,
                                         0, 0, 404, 218),
          "shape alone matches: baseAddr is a snapshot, not an identity");
    check(!now_content_probe_pixmap_match(0x0000u, 0, 0, 404, 218,
                                          0x00801000u, 0x8660u,
                                          0, 0, 404, 218,
                                          0x00801000u, 0x8660u,
                                          0, 0, 404, 218),
          "no CGrafPort discriminator, no port");
    check(!now_content_probe_pixmap_match(0xC000u, 0, 0, 404, 200,
                                          0x00801000u, 0x8660u,
                                          0, 0, 404, 218,
                                          0x00801000u, 0x8660u,
                                          0, 0, 404, 218),
          "a port rect that disagrees with the blit is not the source");
    check(!now_content_probe_pixmap_match(0xC000u, 0, 0, 404, 218,
                                          0x00801000u, 0x8660u,
                                          0, 0, 404, 200,
                                          0x00801000u, 0x8660u,
                                          0, 0, 404, 218),
          "a pixmap whose bounds disagree is not the source either");
    check(!now_content_probe_pixmap_match(0xC000u, 0, 0, 0, 0,
                                          0x00801000u, 0x8660u,
                                          0, 0, 0, 0,
                                          0x00801000u, 0x8660u,
                                          0, 0, 0, 0),
          "zero-area matches nothing on this route too");
}

/* The blit's source port (013 slice B): which hooked offscreen row owns
   the composite a bits hook was handed. Every refusal here is a blitsrc
   record that must NOT be emitted - absence is the pre-join behaviour,
   and a wrong join draws one window's content inside another. */
static void test_blit_source(void)
{
    NowContentBlitSourceRow rows[3];
    int i;

    for (i = 0; i < 3; ++i) {
        rows[i].port = 0x1f470000u + (NowContentU32)i * 0x100u;
        rows[i].a5 = 0x00123456u;
        rows[i].offscreen = 1;
        rows[i].pixmap = 0x00445500u + (NowContentU32)i * 4u;
        rows[i].pixmap_deref = 0x1e950000u + (NowContentU32)i * 0x1000u;
        rows[i].port_version = 0xC001u;
        rows[i].rect_l = 0; rows[i].rect_t = 0;
        rows[i].rect_r = (NowContentS16)(100 + 10 * i);
        rows[i].rect_b = 90;
        rows[i].base = 0x00800000u + (NowContentU32)i * 0x100u;
        rows[i].row_bytes = (NowContentU16)(0x8000u | (unsigned)(64 + 2 * i));
        rows[i].pm_l = 0; rows[i].pm_t = 0;
        rows[i].pm_r = (NowContentS16)(100 + 10 * i);
        rows[i].pm_b = 90;
    }

    /* Identity route: the deref IS the sighted record. */
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             (long)0x1f470100u, "the owning offscreen row names its port");
    /* Shape route: the sighted record is a COPY (no deref matches), and
       only row 2's geometry agrees. This is the route the control
       measured necessary - the bottleneck receives a copied PixMap. */
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1eb6aaaeu,
                                           0x00999999u,
                                           (NowContentU16)(0x8000u | 68u),
                                           0, 0, 120, 90),
             (long)0x1f470200u, "a copied record still resolves by shape");
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1eb6aaaeu,
                                           0u, (NowContentU16)(0x8000u | 64u),
                                           0, 0, 401, 90),
             0, "a shape no row carries resolves to nothing, not a guess");
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0u,
                                           0u, 0u, 0, 0, 100, 90),
             0, "a NULL source pointer matches nothing");
    check_eq((long)now_content_blit_source(rows, 3, 0u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             0, "no armed context, no join");
    check_eq((long)now_content_blit_source(NULL, 3, 0x00123456u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             0, "a NULL table matches nothing");
    check_eq((long)now_content_blit_source(rows, 0, 0x00123456u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             0, "an empty table matches nothing");

    rows[1].offscreen = 0;
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             0, "a window row never claims a blit source");
    rows[1].offscreen = 1;

    rows[1].a5 = 0x00999999u;
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             0, "a row from another armed context never claims one");
    rows[1].a5 = 0x00123456u;

    rows[1].pixmap = 0;
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             0, "a row that lost its handle cannot vouch for a deref");
    rows[1].pixmap = 0x00445504u;

    /* Two rows claiming one pixmap is a table defect, and picking either
       is the plan's own stop condition: refuse the join instead. */
    rows[2].pixmap_deref = 0x1e951000u;
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1e951000u,
                                           0u, 0u, 0, 0, 0, 0),
             0, "an ambiguous claim refuses rather than picks a window");
    rows[2].pixmap_deref = 0x1e952000u;

    /* And the same refusal when identity claims one row while shape
       claims another - the two routes must agree on ONE owner. */
    check_eq((long)now_content_blit_source(rows, 3, 0x00123456u, 0x1e951000u,
                                           0u, (NowContentU16)(0x8000u | 68u),
                                           0, 0, 120, 90),
             0, "identity and shape claiming different rows refuses");
}

static void test_arm_expiry(void)
{
    NowContentRequest r = good_request();

    r.arm_expiry = 0;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 1u),
             kNowContentVerdictExpired, "no deadline is expired on sight");
    /* And at EVERY tick, which is not the same statement. An absent
       deadline is zero, and the signed difference against zero is
       negative - "in the future" - for the whole upper half of the tick
       range. So a machine up for more than ~414 days would arm a request
       that named no deadline at all, if the early return above were not
       there. Found by mutation: deleting that return survived a suite
       that only ever asked at low tick counts. */
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 0x80000000u),
             kNowContentVerdictExpired, "no deadline is expired late too");
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 0xFFFFFFFFu),
             kNowContentVerdictExpired, "no deadline is expired at the wrap");

    r.arm_expiry = 5000u;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 5000u),
             kNowContentVerdictExpired, "the deadline tick itself is expired");
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 5001u),
             kNowContentVerdictExpired, "past the deadline is expired");

    /* Expiry is decided BEFORE context, so a lapsed request retires in
       whatever process pumps next rather than waiting for the target to
       run again. A target that quit must not be able to keep a request
       alive by never pumping. */
    check_eq(now_content_arm_verdict(&r, 0x00999999u, 6000u),
             kNowContentVerdictExpired,
             "a lapsed request expires in a NON-target context");

    /* TickCount wraps at 2^32. A signed difference keeps a deadline just
       across the wrap in the future, where an unsigned one would read it
       as ancient history and retire a live request. */
    r.arm_expiry = 0x00000064u;              /* 100 ticks after the wrap */
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 0xFFFFFFF0u),
             kNowContentVerdictArmed, "a deadline across the tick wrap is future");
    r.arm_expiry = 0xFFFFFFF0u;
    check_eq(now_content_arm_verdict(&r, 0x00123456u, 0x00000064u),
             kNowContentVerdictExpired, "a deadline before the wrap is past");
}

static void test_arm_null_request(void)
{
    check_eq(now_content_arm_verdict(NULL, 0x123u, 1u),
             kNowContentVerdictIdle, "a null request is idle");
}

/* ---- the ring -------------------------------------------------------- */

/* A block with a SMALL ring, which is the only way the wrap and tail paths
   are reachable at all: a 64 KiB ring needs thousands of records to reach
   its end, and a test that needs thousands of records to touch a branch is
   a test nobody trusts. ring_cap is a field for this reason. */
typedef struct {
    NowContentBlock block;
} TestBlock;

static TestBlock *make_block(NowContentU32 cap)
{
    TestBlock *tb = calloc(1, sizeof(TestBlock));

    if (tb == NULL) {
        printf("FAIL out of memory\n");
        exit(1);
    }
    tb->block.ring_cap = cap;
    tb->block.ticks = 1234u;
    return tb;
}

/* Walk the ring the way a reader does - step by each record's own size -
   and report how many records it sees before it has consumed `bytes`.
   Returns -1 if it ever lands on a record whose size cannot be right,
   which is exactly the corruption the tail invariant exists to prevent. */
static int walk_records(const NowContentBlock *b, NowContentU32 from,
                        NowContentU32 to, int *ops, int max_ops)
{
    NowContentU32 c = from;
    int n = 0;

    while (c < to) {
        NowContentU32 pos = c % b->ring_cap;
        const NowContentRecHeader *h;

        if (b->ring_cap - pos < sizeof(NowContentRecHeader)) {
            return -1;                  /* a tail too short to hold a header */
        }
        h = (const NowContentRecHeader *)(const void *)&b->ring[pos];
        if (h->size < sizeof(NowContentRecHeader)) {
            return -1;                  /* a size that cannot be a record */
        }
        if (pos + h->size > b->ring_cap) {
            return -1;                  /* a record that crosses the end */
        }
        if (n < max_ops) {
            ops[n] = h->op;
        }
        n++;
        c += h->size;
        if (n > 4096) {
            return -1;                  /* runaway */
        }
    }
    return c == to ? n : -1;
}

static void test_ring_basic_append(void)
{
    TestBlock *tb = make_block(4096u);
    NowContentLinePayload pl;
    const NowContentRecHeader *h;

    memset(&pl, 0, sizeof(pl));
    pl.from_h = 10; pl.from_v = 20; pl.to_h = 30; pl.to_v = 40;

    check_eq(now_content_ring_put(&tb->block, kNowContentOpLine, 0,
                                  0x00ABCDEFu, &pl, sizeof(pl)),
             1, "a line record commits");
    check_eq((long)tb->block.write_cursor, 44, "v2 header + 12-byte payload");
    h = (const NowContentRecHeader *)(const void *)&tb->block.ring[0];
    check_eq(h->op, kNowContentOpLine, "op recorded");
    check_eq((long)h->port, 0x00ABCDEF, "port recorded");
    check_eq((long)h->ticks, 1234, "ticks stamped from the block");
    check(memcmp(&tb->block.ring[sizeof(NowContentRecHeader)], &pl,
                 sizeof(pl)) == 0, "payload copied verbatim");
    check_eq((long)(tb->block.seq % 2), 0, "seqlock ends even");
    check_eq((long)tb->block.counters.dropped, 0, "nothing dropped");
    free(tb);
}

static void test_ring_odd_payload_pads_even(void)
{
    TestBlock *tb = make_block(4096u);
    unsigned char pl[13];
    const NowContentRecHeader *h;

    memset(pl, 0xA5, sizeof(pl));
    check_eq(now_content_ring_put(&tb->block, kNowContentOpText, 0, 1u,
                                  pl, sizeof(pl)),
             1, "an odd payload commits");
    h = (const NowContentRecHeader *)(const void *)&tb->block.ring[0];
    check_eq(h->size, 46, "32 + 13 rounds up to 46, not 45");
    check_eq((long)(tb->block.write_cursor % 2), 0, "cursor stays even");
    free(tb);
}

static void test_ring_oversize_is_dropped_not_wrapped(void)
{
    TestBlock *tb = make_block(64u);
    unsigned char pl[128];

    memset(pl, 0, sizeof(pl));
    check_eq(now_content_ring_put(&tb->block, kNowContentOpText, 0, 1u,
                                  pl, sizeof(pl)),
             0, "a record larger than the ring is dropped");
    check_eq((long)tb->block.counters.dropped, 1, "and counted");
    check_eq((long)tb->block.write_cursor, 0, "and the cursor does not move");
    check_eq((long)(tb->block.seq % 2), 0, "seqlock not left odd");
    free(tb);
}

/* The tail-absorb path: a record that would leave fewer bytes than a
   header grows to swallow them, so the ring ends exactly full and the
   next record starts at zero with no pad needed. */
static void test_ring_absorbs_a_short_tail(void)
{
    TestBlock *tb = make_block(228u);
    NowContentLinePayload pl;
    const NowContentRecHeader *h;
    int ops[32];
    int n;
    int i;

    memset(&pl, 0, sizeof(pl));
    /* 44 bytes each: four reach 176, and the fifth would leave 8 - too few
       for a v2 header - so it absorbs them and becomes 52. */
    for (i = 0; i < 5; ++i) {
        check_eq(now_content_ring_put(&tb->block, kNowContentOpLine, 0,
                                      (NowContentU32)i, &pl, sizeof(pl)),
                 1, "fill record commits");
    }
    check_eq((long)tb->block.write_cursor, 228,
             "the fifth record absorbed the 8-byte tail");
    h = (const NowContentRecHeader *)(const void *)&tb->block.ring[176];
    check_eq(h->size, 52, "and says so in its own size field");
    check_eq(h->op, kNowContentOpLine, "an absorbed record is still its op");

    n = walk_records(&tb->block, 0, 228u, ops, 32);
    check_eq(n, 5, "a reader sees exactly five records in the lap");

    /* The sixth starts at 0 with no WRAP record, because there is no tail
       left to pad. */
    check_eq(now_content_ring_put(&tb->block, kNowContentOpLine, 0, 99u,
                                  &pl, sizeof(pl)),
             1, "the sixth record commits at the ring start");
    h = (const NowContentRecHeader *)(const void *)&tb->block.ring[0];
    check_eq((long)h->port, 99, "the ring start now holds the sixth record");
    free(tb);
}

/* The WRAP path proper: a tail big enough to hold a header but too small
   for the record that wants it gets a WRAP record, and the real record
   starts at zero. This is reachable only when a LARGER record follows
   smaller ones, which is why it needs its own case. */
static void test_ring_pads_a_usable_tail_with_wrap(void)
{
    TestBlock *tb = make_block(224u);
    NowContentLinePayload line;
    unsigned char big[36];
    const NowContentRecHeader *h;
    int ops[32];
    int n;
    int i;

    memset(&line, 0, sizeof(line));
    memset(big, 0x3C, sizeof(big));
    for (i = 0; i < 4; ++i) {
        (void)now_content_ring_put(&tb->block, kNowContentOpLine, 0,
                                   (NowContentU32)i, &line, sizeof(line));
    }
    check_eq((long)tb->block.write_cursor, 176, "four 44-byte records");
    n = walk_records(&tb->block, 0, 176u, ops, 32);
    check_eq(n, 4, "and a reader walks all four");

    /* 32 + 36 = 68 wanted, 48 available: too big to fit, and the tail is
       big enough to hold a WRAP record. */
    check_eq(now_content_ring_put(&tb->block, kNowContentOpBits, 0, 77u,
                                  big, sizeof(big)),
             1, "the oversized-for-the-tail record commits");
    h = (const NowContentRecHeader *)(const void *)&tb->block.ring[176];
    check_eq(h->op, kNowContentOpWrap, "the tail holds a WRAP record");
    check_eq(h->size, 48, "sized to the tail exactly");
    h = (const NowContentRecHeader *)(const void *)&tb->block.ring[0];
    check_eq(h->op, kNowContentOpBits, "and the real record restarted at 0");
    check_eq((long)tb->block.write_cursor, 224 + 68,
             "cursor covers the pad and the record");

    /* The wrapping record is 48 bytes at ring[0], so it has overwritten
       the first two records of the lap - which is what a ring does, and
       what the overrun counter on the reader's side is for. What must
       still hold is that a reader whose cursor is BEHIND the damage walks
       cleanly to the end of the lap: two records and the pad. */
    n = walk_records(&tb->block, 88u, 224u, ops, 32);
    check_eq(n, 3, "a reader behind the overwrite walks to the lap's end");
    check_eq(ops[2], kNowContentOpWrap, "ending on the pad");
    /* And walking the NEW lap finds the record that caused all this. */
    n = walk_records(&tb->block, 224u, 224u + 68u, ops, 32);
    check_eq(n, 1, "the new lap holds the wrapping record");
    check_eq(ops[0], kNowContentOpBits, "which is the one that did not fit");
    free(tb);
}

/*
 * THE TAIL INVARIANT, and the reason this port diverges from upstream.
 *
 * Upstream's ring advanced its cursor past a tail too short to hold a
 * header WITHOUT writing anything into it. A reader stepping record by
 * record then reads those bytes as a header: a full header of whatever was
 * there, whose `size` field decides where it goes next. That path never
 * ran anywhere - the milestone that would have exercised it did not pass -
 * so it is a defect to fix, not a measurement to preserve.
 *
 * This drives a ring to every tail width a header could straddle and
 * checks that a reader can walk the whole thing. With the absorb removed,
 * walk_records returns -1.
 */
static void test_ring_never_leaves_a_short_tail(void)
{
    NowContentU32 cap;
    int payload;

    for (cap = 64u; cap <= 160u; cap += 2u) {
        for (payload = 0; payload <= 24; ++payload) {
            TestBlock *tb = make_block(cap);
            unsigned char pl[32];
            NowContentU32 lap;
            int ops[512];
            int r;
            int i;

            memset(pl, 0x5A, sizeof(pl));
            /* Fill well past one lap so every alignment is reached. */
            for (i = 0; i < 40; ++i) {
                (void)now_content_ring_put(&tb->block, kNowContentOpRect, 0,
                                           (NowContentU32)i, pl,
                                           (NowContentU16)payload);
                /* After EVERY commit, the tail is zero or a whole header. */
                lap = tb->block.write_cursor % cap;
                if (lap != 0 && cap - lap < sizeof(NowContentRecHeader)) {
                    printf("FAIL short tail: cap %lu payload %d rem %lu\n",
                           (unsigned long)cap, payload,
                           (unsigned long)(cap - lap));
                    failures++;
                    break;
                }
            }
            /* And a reader can walk the last complete lap. */
            r = walk_records(&tb->block,
                             (tb->block.write_cursor / cap) * cap,
                             tb->block.write_cursor, ops, 512);
            if (r < 0) {
                printf("FAIL unwalkable ring: cap %lu payload %d\n",
                       (unsigned long)cap, payload);
                failures++;
            }
            free(tb);
        }
    }
}

static void test_ring_null_block(void)
{
    check_eq(now_content_ring_put(NULL, kNowContentOpLine, 0, 1u, NULL, 0),
             0, "a null block commits nothing");
}

/* A ring too small to hold two headers has no honest wrap behaviour, so it
   refuses rather than inventing one. */
static void test_ring_degenerate_cap(void)
{
    TestBlock *tb = make_block(16u);

    check_eq(now_content_ring_put(&tb->block, kNowContentOpLine, 0, 1u, NULL, 0),
             0, "a ring under two headers refuses");
    check_eq((long)tb->block.counters.dropped, 1, "and counts the drop");
    free(tb);
}

/* ---- state deltas ---------------------------------------------------- */

static NowContentPortState a_state(void)
{
    NowContentPortState s;

    s.clip_l = 0; s.clip_t = 0; s.clip_r = 400; s.clip_b = 300;
    s.origin_h = 0; s.origin_v = 0;
    s.fg_r = 0; s.fg_g = 0; s.fg_b = 0;
    s.bg_r = 0xFFFF; s.bg_g = 0xFFFF; s.bg_b = 0xFFFF;
    return s;
}

static void test_state_first_time_emits_everything(void)
{
    NowContentPortState shadow = a_state();
    NowContentPortState live = a_state();

    check_eq((long)now_content_state_deltas(&shadow, 0, &live),
             kNowContentDeltaOrigin | kNowContentDeltaClip
             | kNowContentDeltaFg | kNowContentDeltaBg,
             "an unrecorded port emits all four, identical or not");
    check_eq((long)now_content_state_deltas(NULL, 1, &live),
             kNowContentDeltaOrigin | kNowContentDeltaClip
             | kNowContentDeltaFg | kNowContentDeltaBg,
             "no shadow at all emits all four");
}

static void test_state_unchanged_emits_nothing(void)
{
    NowContentPortState shadow = a_state();
    NowContentPortState live = a_state();

    check_eq((long)now_content_state_deltas(&shadow, 1, &live), 0,
             "a steady redraw emits no state at all");
}

static void test_state_each_field_alone(void)
{
    NowContentPortState shadow = a_state();
    NowContentPortState live;

    live = a_state(); live.origin_h = 5;
    check_eq((long)now_content_state_deltas(&shadow, 1, &live),
             kNowContentDeltaOrigin, "origin h alone");
    live = a_state(); live.origin_v = 5;
    check_eq((long)now_content_state_deltas(&shadow, 1, &live),
             kNowContentDeltaOrigin, "origin v alone");
    live = a_state(); live.clip_l = 1;
    check_eq((long)now_content_state_deltas(&shadow, 1, &live),
             kNowContentDeltaClip, "clip left alone");
    live = a_state(); live.clip_b = 1;
    check_eq((long)now_content_state_deltas(&shadow, 1, &live),
             kNowContentDeltaClip, "clip bottom alone");
    live = a_state(); live.fg_g = 0x8000;
    check_eq((long)now_content_state_deltas(&shadow, 1, &live),
             kNowContentDeltaFg, "fg green alone");
    live = a_state(); live.bg_b = 0;
    check_eq((long)now_content_state_deltas(&shadow, 1, &live),
             kNowContentDeltaBg, "bg blue alone");

    /* Negative coordinates are ordinary here - a scrolled port's origin
       goes negative, which is the MoveBits case the host relies on. */
    live = a_state(); live.origin_v = -33;
    check_eq((long)now_content_state_deltas(&shadow, 1, &live),
             kNowContentDeltaOrigin, "a negative origin is a change");
}

static void test_state_null_live(void)
{
    NowContentPortState shadow = a_state();

    check_eq((long)now_content_state_deltas(&shadow, 1, NULL), 0,
             "no live state means no deltas");
}

/* ---- the layout itself ----------------------------------------------- */

/* The static asserts in the header do the real work at compile time on all
   three compilers. This checks the two numbers a reader on the wire has to
   agree with us about, so a change to them fails here as well as there. */
/* ---- the arm-time census's verdict ---------------------------------
 *
 * WHAT EACH CASE IS DEFENDING, because a predicate that answers yes too
 * often here does not fail a test, it writes four bytes into somebody
 * else's heap. The happy case is one real world; every other case is a
 * shape that will occur many thousands of times in a single sweep of a
 * live application heap, and must answer no.
 */
static void test_census_match(void)
{
    /* A GWorld as NewGWorld builds one: colour port, its own rect, and a
       pixmap whose bounds are the same rectangle. */
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000 | 688,
                                      0, 0, 344, 238),
             1, "a colour port whose pixmap bounds are its own rect is a world");

    /* THE WINDOW CASE, and it is the one this predicate exists to get
       right without a list walk. A window's portRect is LOCAL and its
       portPixMap is the SCREEN's, whose bounds are the whole display in
       global coordinates. The two disagree, and so this says no. */
    check_eq(now_content_census_match(0xC001, 0x00a80000,
                                      0, 0, 344, 238,
                                      0x9c000000, 0x8000 | 2560,
                                      0, 0, 640, 480),
             0, "a window port's rect and the screen pixmap's bounds differ");

    /* The discriminator. A classic B&W GrafPort is the same SIZE and a
       different SHAPE, so reading grafProcs on one lands in the middle
       of another field - the reason nothing may be written until this
       passes. */
    check_eq(now_content_census_match(0x0001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000 | 688,
                                      0, 0, 344, 238),
             0, "a port that is not a colour port is refused");

    /* Zeroed and near-zeroed blocks. A live heap is full of both, and
       every one of them is walked. */
    check_eq(now_content_census_match(0xC001, 0,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000 | 688,
                                      0, 0, 344, 238),
             0, "a null portPixMap is refused");
    check_eq(now_content_census_match(0xC001, 0x1e950001,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000 | 688,
                                      0, 0, 344, 238),
             0, "an odd portPixMap is not a handle");
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0, 0x8000 | 688,
                                      0, 0, 344, 238),
             0, "a zero baseAddr is a zeroed block, not a world");
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 0, 0,
                                      0x1ea00000, 0x8000 | 688,
                                      0, 0, 0, 0),
             0, "an empty rectangle is not a world however well it agrees");

    /* rowBytes' high bit is QuickDraw's own "this record is a PixMap".
       Without it the record is a BitMap - somebody else's structure
       however plausibly the rest of it reads. */
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0x1ea00000, 688,
                                      0, 0, 344, 238),
             0, "a BitMap-flagged record is not a PixMap");
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000,
                                      0, 0, 344, 238),
             0, "a zero stride is refused");

    /* The stride sanity check. Four rectangle words can agree by
       coincidence over an unrelated stride; a row too narrow to hold
       the pixels at ONE bit each cannot be this pixmap's. */
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000 | 8,
                                      0, 0, 344, 238),
             0, "a stride too small to hold one row at 1bpp is refused");
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000 | 43,
                                      0, 0, 344, 238),
             1, "exactly one row at 1bpp is allowed - shallowness is legal");

    /* Partial agreement is not agreement. A block whose rect matches the
       pixmap in three of four coordinates is a coincidence, and the
       whole point of using shape as the key is that all of it must hold. */
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      0, 0, 344, 238,
                                      0x1ea00000, 0x8000 | 688,
                                      0, 0, 344, 239),
             0, "three of four coordinates agreeing is not a match");

    /* A world at a nonzero origin. GWorlds are usually built at (0,0)
       but nothing requires it, and a predicate that only ever saw the
       origin would look correct for the wrong reason. */
    check_eq(now_content_census_match(0xC001, 0x1e950000,
                                      -20, -8, 324, 230,
                                      0x1ea00000, 0x8000 | 688,
                                      -20, -8, 324, 230),
             1, "a world at a nonzero origin is still a world");
}

static void test_layout(void)
{
    check_eq((long)sizeof(NowContentRecHeader), 32, "v2 record header is 32");
    check_eq((long)sizeof(NowContentBlock), 368 + kNowContentRingCap,
             "block is v1 prefix + ring + v2 + probe + qdext + census tails");
    check_eq((long)offsetof(NowContentBlock, probe_pending_pixmap),
             192 + kNowContentRingCap,
             "the probe tail starts where the v2 tail ended");
    check_eq((long)offsetof(NowContentBlock, qdext_calls),
             292 + kNowContentRingCap,
             "and the qdext tail starts where the probe tail ended");
    check_eq((long)offsetof(NowContentBlock, census_runs),
             324 + kNowContentRingCap,
             "and the census tail starts where the qdext tail ended");
    check_eq((long)kNowContentArmCommit, 0x4E576361L, "'NWca'");
    check_eq((long)kNowContentBlockMagic, 0x4E576362L, "'NWcb'");
    check(kNowContentArmCommit != 1 && kNowContentArmCommit != 0,
          "the commit word is not a value zeroed memory produces");
}

int main(void)
{
    test_lifecycle_exact_window_and_redraw();
    test_lifecycle_close_relaunch_and_retarget();
    test_lifecycle_disarm_expiry_death_and_suspension();
    test_arm_happy_path();
    test_arm_without_a_target_refuses();
    test_arm_wrong_context_refuses();
    test_arm_commit_word_is_required();
    test_arm_plane_bit_gates_everything();
    test_arm_mode_is_fail_closed();
    test_arm_expiry();
    test_arm_null_request();
    test_arm_probe_mode();
    test_probe_match();
    test_probe_pixmap_match();
    test_blit_source();
    test_census_match();

    test_ring_basic_append();
    test_ring_odd_payload_pads_even();
    test_ring_oversize_is_dropped_not_wrapped();
    test_ring_absorbs_a_short_tail();
    test_ring_pads_a_usable_tail_with_wrap();
    test_ring_never_leaves_a_short_tail();
    test_ring_null_block();
    test_ring_degenerate_cap();

    test_state_first_time_emits_everything();
    test_state_unchanged_emits_nothing();
    test_state_each_field_alone();
    test_state_null_live();

    test_layout();

    if (failures != 0) {
        printf("%d failed\n", failures);
        return 1;
    }
    printf("content plane ok\n");
    return 0;
}
