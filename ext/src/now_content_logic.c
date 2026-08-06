/*
 * now_content_logic.c - the content plane's decisions, with no Toolbox in
 * them.
 *
 * This file exists because of what the rest of the plane is: draw-time
 * resident code inside another process, which no gate short of a Macintosh
 * can execute. peek_oracle.c and scene_build.c are the precedent - the
 * decisions get separated from the calls that can only be made on the
 * machine, so a host cc can run them. Everything here is reachable from
 * now-guest-ppc/tests/content_plane_test.c.
 *
 * Three decisions live here, and they are the three that can hurt:
 *
 *   1. WHETHER TO HOOK AT ALL (now_content_arm_verdict). Fail-closed in
 *      every direction: a request with no target instruments nothing, not
 *      everything.
 *   2. WHERE A RECORD GOES (now_content_ring_put). Bounded arithmetic over
 *      a fixed buffer; the one path in the plane that upstream shipped but
 *      never ran.
 *   3. WHAT STATE CHANGED (now_content_state_deltas). Pure comparison.
 *
 * The Toolbox half (now_content.c) reads ports and installs procs and does
 * nothing else it could have done here.
 */

#include "content_table.h"

/* The whole point of the commit word: a request is a request only when
   every field of it is one. Order of checks is the order of severity, so
   the counter that gets bumped names the most specific thing wrong. */
int now_content_arm_verdict(const NowContentRequest *req,
                            NowContentU32 current_a5,
                            NowContentU32 now_ticks)
{
    NowContentU32 mode;

    if (req == NULL) {
        return kNowContentVerdictIdle;
    }
    /* The plane's own capability bit in the shared table gates everything
       below it. P1's shape, deliberately: one place says "this plane may
       run at all", the block says "on whom". */
    if ((req->plane_bits & (NowContentU32)kNowPeekTableCapContent) == 0) {
        return kNowContentVerdictIdle;
    }
    if (req->arm_commit != (NowContentU32)kNowContentArmCommit) {
        return kNowContentVerdictIdle;
    }
    mode = req->mode;
    if (mode != (NowContentU32)kNowContentModeCount
        && mode != (NowContentU32)kNowContentModeRecord
        && mode != (NowContentU32)kNowContentModeProbe) {
        /* Includes mode off, and anything outside the enum. A mode we do
           not recognise is not a mode we act on. */
        return kNowContentVerdictIdle;
    }

    /* A commit word with no target is the defect this plane was rewritten
       to remove, so it gets its own verdict rather than falling through to
       a context mismatch. */
    if (req->arm_a5 == 0) {
        return kNowContentVerdictNoTarget;
    }
    if (req->arm_window == 0 || req->arm_generation == 0) {
        return kNowContentVerdictNoTarget;
    }

    /* Expiry before context: a lapsed request must retire in WHATEVER
       process pumps next, or retiring it would depend on the target still
       being alive - which is the failure the deadline exists to cover.
       Absent deadline = expired on sight. Signed difference is
       TickCount-wrap safe. */
    if (req->arm_expiry == 0) {
        return kNowContentVerdictExpired;
    }
    /* The signed comparison is written out rather than cast through a
       signed type, because `long` is 32 bits on the 68K that runs this and
       64 bits on the host cc that tests it - and a 64-bit cast of a 32-bit
       unsigned difference is never negative, so the wrap test would pass
       on the machine and be dead on the gate. Top bit of the difference
       clear means now >= expiry. */
    if (((now_ticks - req->arm_expiry) & 0x80000000UL) == 0) {
        return kNowContentVerdictExpired;
    }

    /* current_a5 == 0 is a context with no A5 world; it can never be the
       named target, and arm_a5 is already known nonzero. */
    if (req->arm_a5 != current_a5) {
        return kNowContentVerdictOtherContext;
    }
    return kNowContentVerdictArmed;
}

NowContentU32 now_content_lifecycle_decide(
    const NowContentLifecycleFacts *facts)
{
    NowContentU32 actions = 0;
    int owns_slot;

    if (facts == NULL) {
        return 0;
    }
    owns_slot = facts->has_slot
        && facts->slot_a5 == facts->current_a5;

    if (facts->verdict == kNowContentVerdictExpired) {
        actions |= kNowContentLifeRetire;
    }

    if (facts->verdict == kNowContentVerdictArmed) {
        if (!facts->window_live) {
            if (owns_slot) {
                actions |= kNowContentLifeForget;
            }
            return actions;
        }
        if (!facts->has_slot
            || facts->slot_window != facts->request_window
            || facts->slot_generation != facts->request_generation) {
            if (owns_slot) {
                if (facts->window_live && facts->hook_owned) {
                    actions |= kNowContentLifeRestore;
                }
                actions |= kNowContentLifeForget;
            }
            actions |= kNowContentLifeInstall;
        }
        if (!facts->redraw_requested) {
            actions |= kNowContentLifeInvalidate;
        }
        return actions;
    }

    /* Disarm, expiry, retarget, and a lapsed target all remove only an
       owning-context slot. A suspended target cannot be entered; its hooks
       remain strict pass-through after the global request retires and are
       restored on its next owning-context event-loop pass. */
    if (owns_slot) {
        if (facts->window_live && facts->hook_owned) {
            actions |= kNowContentLifeRestore;
        }
        actions |= kNowContentLifeForget;
    }
    return actions;
}

/*
 * Append one record to the ring.
 *
 * The invariant, and it is the reason this differs from upstream: after
 * every call, the bytes remaining at the ring's end are either zero or at
 * least a whole header. A reader walks records by stepping over each
 * record's own `size`, so a tail too short to hold a header would be read
 * AS a header - a full header of whatever was there before, whose `size`
 * field then decides where the reader goes next. Upstream's ring advanced
 * its cursor past such a tail without writing anything into it. That path
 * never ran anywhere (its milestone did not pass), so it is a defect this
 * port fixes rather than a measurement it preserves.
 *
 * The fix keeps the reader's rule intact instead of adding a case to it:
 * a record that would leave a too-short tail absorbs it, so `size` can
 * exceed header + payload and the trailing bytes are simply skipped.
 *
 * Bounded, allocation-free, no memory movement: the rules the jGNE
 * fast path is written under, and this runs somewhere stricter.
 */
int now_content_ring_put(NowContentBlock *block,
                         unsigned char op, unsigned char flags,
                         NowContentU32 port,
                         const void *payload, NowContentU16 payload_len)
{
    NowContentU32 cap;
    NowContentU32 pos;
    NowContentU32 remain;
    NowContentU32 rec_size;
    NowContentRecHeader *h;
    unsigned char *dst;
    NowContentU16 i;

    if (block == NULL) {
        return 0;
    }
    cap = block->ring_cap;
    if (cap < (NowContentU32)(2 * sizeof(NowContentRecHeader))) {
        block->counters.dropped++;
        return 0;
    }
    rec_size = (NowContentU32)sizeof(NowContentRecHeader) + payload_len;
    rec_size = (rec_size + 1u) & ~1u;              /* even */
    if (rec_size > cap) {
        block->counters.dropped++;
        return 0;
    }

    block->seq++;                                  /* seqlock -> odd */

    pos = block->write_cursor % cap;
    remain = cap - pos;
    if (rec_size > remain) {
        /* Pad to the end with a WRAP record. The invariant guarantees
           remain is a whole header or more, so this always fits. */
        h = (NowContentRecHeader *)(void *)&block->ring[pos];
        h->size = (NowContentU16)remain;
        h->op = kNowContentOpWrap;
        h->flags = 0;
        h->port = 0;
        h->ticks = block->ticks;
        block->write_cursor += remain;
        pos = 0;
        remain = cap;
    }
    /* Absorb a tail too short to hold the next header, so the invariant
       holds for the NEXT call rather than being repaired by it. */
    if (remain - rec_size != 0
        && remain - rec_size < (NowContentU32)sizeof(NowContentRecHeader)) {
        rec_size = remain;
    }

    h = (NowContentRecHeader *)(void *)&block->ring[pos];
    h->size = (NowContentU16)rec_size;
    h->op = op;
    h->flags = flags;
    h->port = port;
    h->ticks = block->ticks;
    h->a5 = block->active_a5;
    h->psn_hi = block->active_psn_hi;
    h->psn_lo = block->active_psn_lo;
    h->display_epoch = block->display_epoch;
    h->generation = block->active_generation;
    if (payload_len > 0 && payload != NULL) {
        dst = &block->ring[pos + sizeof(NowContentRecHeader)];
        for (i = 0; i < payload_len; ++i) {
            dst[i] = ((const unsigned char *)payload)[i];
        }
    }
    block->write_cursor += rec_size;

    block->seq++;                                  /* seqlock -> even */
    return 1;
}

/* Which STATE records the live port state needs relative to what was last
   recorded. Does not touch the shadow: the caller commits it only after
   the records are actually in the ring, so a dropped record can never
   leave the shadow claiming a state the host never saw. */
NowContentU32 now_content_state_deltas(const NowContentPortState *shadow,
                                       int valid,
                                       const NowContentPortState *live)
{
    NowContentU32 out = 0;

    if (live == NULL) {
        return 0;
    }
    if (!valid || shadow == NULL) {
        return (NowContentU32)(kNowContentDeltaOrigin | kNowContentDeltaClip
                               | kNowContentDeltaFg | kNowContentDeltaBg);
    }
    if (live->origin_h != shadow->origin_h || live->origin_v != shadow->origin_v) {
        out |= (NowContentU32)kNowContentDeltaOrigin;
    }
    if (live->clip_l != shadow->clip_l || live->clip_t != shadow->clip_t
        || live->clip_r != shadow->clip_r || live->clip_b != shadow->clip_b) {
        out |= (NowContentU32)kNowContentDeltaClip;
    }
    if (live->fg_r != shadow->fg_r || live->fg_g != shadow->fg_g
        || live->fg_b != shadow->fg_b) {
        out |= (NowContentU32)kNowContentDeltaFg;
    }
    if (live->bg_r != shadow->bg_r || live->bg_g != shadow->bg_g
        || live->bg_b != shadow->bg_b) {
        out |= (NowContentU32)kNowContentDeltaBg;
    }
    return out;
}

/* The probe's port match. An offscreen CGrafPort is identified, never
   assumed: the handle in portPixMap must BE the sighted pixmap's handle,
   the Color QuickDraw discriminator must pass, and portRect must equal
   the pixmap's bounds. The last test is what makes a linear zone scan
   honest - a free block that still holds a stale copy of the handle
   value fails it unless it also holds the whole port, in which case it
   IS the port, merely disposed, and the repair sweep's stale check is
   the guard that matters. A zero-area rect never matches: a GWorld has
   extent, and a zeroed candidate must not pass on zeroed wants. */
int now_content_probe_match(NowContentU32 cand_pixmap_handle,
                            NowContentU16 cand_port_version,
                            NowContentS16 cand_l, NowContentS16 cand_t,
                            NowContentS16 cand_r, NowContentS16 cand_b,
                            NowContentU32 want_pixmap_handle,
                            NowContentS16 want_l, NowContentS16 want_t,
                            NowContentS16 want_r, NowContentS16 want_b)
{
    if (want_pixmap_handle == 0
        || cand_pixmap_handle != want_pixmap_handle) {
        return 0;
    }
    if ((cand_port_version & 0xC000U) != 0xC000U) {
        return 0;
    }
    if (want_r <= want_l || want_b <= want_t) {
        return 0;
    }
    return cand_l == want_l && cand_t == want_t
        && cand_r == want_r && cand_b == want_b;
}

/* The deref route's verdict. Weaker key than the handle (a baseAddr is
   one Ptr among many), so it demands MORE agreement: discriminator,
   the candidate port's own rect, what its pixmap points at, and the
   sighted pixmap's shape, all four ways. rowBytes is masked to its
   low 14 bits; the flags above them describe the RECORD, not the
   pixels. Zero baseAddr never matches - it is what a zeroed block
   holds, and half the heap is zeroed blocks. */
int now_content_probe_pixmap_match(NowContentU16 cand_port_version,
                                   NowContentS16 cand_l, NowContentS16 cand_t,
                                   NowContentS16 cand_r, NowContentS16 cand_b,
                                   NowContentU32 cand_base,
                                   NowContentU16 cand_row_bytes,
                                   NowContentS16 pm_l, NowContentS16 pm_t,
                                   NowContentS16 pm_r, NowContentS16 pm_b,
                                   NowContentU32 want_base,
                                   NowContentU16 want_row_bytes,
                                   NowContentS16 want_l, NowContentS16 want_t,
                                   NowContentS16 want_r, NowContentS16 want_b)
{
    /* baseAddr is NOT part of the test any more, and dropping it is the
       whole point. LockPixels relocates the pixmap RECORD - measured
       2026-08-06: the control's own deref sits at 0x1e957660 inside its
       app zone, while the blit it makes under LockPixels reports
       0x1ea53eee, above bkLim and outside that zone entirely. So the
       source pointer, the handle recovered from it, and its baseAddr are
       all snapshots of a moved block. What survives relocation is SHAPE:
       the pixmap's bounds and rowBytes, and the owning port's rect
       agreeing with them. `cand_base` is kept in the signature because
       the caller still reports it, and a caller passing a base is not
       wrong - it is simply no longer decisive. */
    (void)cand_base;
    (void)want_base;
    if ((cand_port_version & 0xC000U) != 0xC000U) {
        return 0;
    }
    if ((cand_row_bytes & 0x3FFFU) != (want_row_bytes & 0x3FFFU)) {
        return 0;
    }
    if (want_r <= want_l || want_b <= want_t) {
        return 0;
    }
    if (cand_l != want_l || cand_t != want_t
        || cand_r != want_r || cand_b != want_b) {
        return 0;
    }
    return pm_l == want_l && pm_t == want_t
        && pm_r == want_r && pm_b == want_b;
}

/* Which hooked offscreen port owns the blit's source PixMap. The caller
   dereferences each row's handle at the same instant it captures
   `src_bits` (013 A2.1: both sides read NOW, so LockPixels relocation
   cannot separate them); this only compares. A row qualifies when it is
   offscreen, in the armed context, holds a handle, and that handle's
   master pointer IS the sighted source. Exactly one may: a second
   claimant means the table holds two rows for one pixmap, and a join
   picked between them draws one window's content inside another - the
   plan's own stop condition - so ambiguity refuses rather than picks. */
NowContentU32 now_content_blit_source(const NowContentBlitSourceRow *rows,
                                      int count,
                                      NowContentU32 armed_a5,
                                      NowContentU32 src_bits)
{
    NowContentU32 found = 0;
    int i;

    if (rows == NULL || src_bits == 0 || armed_a5 == 0) {
        return 0;
    }
    for (i = 0; i < count; ++i) {
        if (!rows[i].offscreen
            || rows[i].a5 != armed_a5
            || rows[i].pixmap == 0
            || rows[i].pixmap_deref != src_bits) {
            continue;
        }
        if (found != 0) {
            return 0;
        }
        found = rows[i].port;
    }
    return found;
}
