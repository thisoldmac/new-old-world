/*
 * qdtrace_read.c - the ring reader, with no Toolbox in it.
 *
 * The precedent is now_content_logic.c one directory over (and
 * peek_oracle.c, and scene_build.c): the decisions that can hurt are
 * separated from the calls only a Macintosh can make, so a host cc runs
 * them. For a ring decoder that is not a nicety. The writer is resident
 * draw-time code inside another process, the record path has never run
 * anywhere on either side, and the failure mode of a bad decoder is not a
 * crash - it is plausible output. A decoder must be executable against a
 * fixture or nothing ever contradicts it.
 *
 * Everything here reads. The only writer in this file is the arm commit,
 * which is four stores in a fixed order, and it is here rather than in
 * the Toolbox half precisely so that the order is somewhere a test and a
 * source gate can both see it.
 *
 * SIZES ARE NEVER TRUSTED. Every `size` this walks is validated against
 * the header minimum, evenness, the ring capacity and the distance to the
 * ring's end, even though the writer's own invariant makes all four
 * redundant. The writer is a separate binary that loads at boot; the one
 * thing certain about the pair is that they will at some point be
 * different builds.
 */

#include "qdtrace.h"

#include <string.h>

/* memcpy rather than a cast through the ring bytes, everywhere. Records
   are 2-aligned by construction, so a record's own 4-aligned header
   fields can still land on a 2-aligned ADDRESS - the 68K and PowerPC
   both survive that and the host cc's sanitisers correctly do not. */
static void copy_out(void *dst, const unsigned char *src, unsigned long n)
{
    memcpy(dst, src, (size_t)n);
}

static int block_ok(const NowContentBlock *block)
{
    NowContentU32 cap;

    if (block == NULL) {
        return 0;
    }
    if (block->magic != (NowContentU32)kNowContentBlockMagic) {
        return 0;
    }
    if (block->format != (NowContentU16)kNowContentFormatV2) {
        return 0;
    }
    cap = block->ring_cap;
    /* An odd capacity would put a 2-aligned record at an odd offset after
       one wrap; a capacity under two headers cannot hold a record plus
       the tail the invariant requires; and a capacity over the array we
       compiled against would walk off the end of it. */
    if ((cap & 1u) != 0 || cap < (NowContentU32)(2 * sizeof(NowContentRecHeader))
        || cap > (NowContentU32)kNowContentRingCap) {
        return 0;
    }
    /* The accretive rule: the block must claim at least the bytes we are
       about to read. */
    if (block->length < (NowContentU32)sizeof(NowContentBlock)) {
        return 0;
    }
    return 1;
}

NowContentU32 now_qdtrace_total_ops(const NowContentCounters *c)
{
    if (c == NULL) {
        return 0;
    }
    /* The ten families plus `other` - every counter that means a drawing
       operation HAPPENED. `dropped` and `skipped_ports` are deliberately
       absent: they are losses, and adding a loss into an op total would
       make a plane that is failing look like a plane that is busy. */
    return c->text + c->line + c->rect + c->rrect + c->oval + c->arc
           + c->poly + c->rgn + c->bits + c->comment + c->other;
}

/* ---- the drain ------------------------------------------------------ */

/* Decode one record's payload by family. Returns 1 when the bytes the
   header claims are enough for the family's payload struct. A record
   whose payload does not fit still reaches the sink with payload_ok = 0:
   an op HAPPENED, and dropping it would understate the traffic in
   exactly the direction that reads as a quiet machine. */
static int decode_payload(NowQDRecord *rec, const unsigned char *body,
                          NowContentU32 body_len)
{
    NowContentU32 want;
    NowContentU32 n;

    switch (rec->op) {
    case kNowContentOpText:
        want = (NowContentU32)sizeof(NowContentTextPayload);
        if (body_len < want) {
            return 0;
        }
        copy_out(&rec->p.text, body, want);
        n = rec->p.text.len;
        if (n > (NowContentU32)kNowContentTextMax) {
            /* `len` is the INLINE count and is bounded by the format. A
               larger one is a record we cannot read; the true run length
               lives in full_len and survives. */
            return 0;
        }
        if (body_len - want < n) {
            return 0;
        }
        copy_out(rec->text, body + want, n);
        rec->text[n] = '\0';
        return 1;
    case kNowContentOpLine:
        want = (NowContentU32)sizeof(NowContentLinePayload);
        if (body_len < want) {
            return 0;
        }
        copy_out(&rec->p.line, body, want);
        return 1;
    case kNowContentOpRect:
    case kNowContentOpRRect:
    case kNowContentOpOval:
    case kNowContentOpArc:
    case kNowContentOpPoly:
    case kNowContentOpRgn:
        want = (NowContentU32)sizeof(NowContentRectPayload);
        if (body_len < want) {
            return 0;
        }
        copy_out(&rec->p.rect, body, want);
        return 1;
    case kNowContentOpBits:
        want = (NowContentU32)sizeof(NowContentBitsPayload);
        if (body_len < want) {
            return 0;
        }
        copy_out(&rec->p.bits, body, want);
        return 1;
    case kNowContentOpState:
        want = (NowContentU32)sizeof(NowContentStatePayload);
        if (body_len < want) {
            return 0;
        }
        copy_out(&rec->p.state, body, want);
        return 1;
    default:
        /* kNowContentOpComment carries its kind in the record-header flags
           and has no payload struct; an unknown op is a newer writer
           and is reported as a header, not swallowed. */
        return 0;
    }
}

void now_qdtrace_drain(const NowContentBlock *block,
                       NowContentU32 cursor,
                       NowContentU32 max_bytes,
                       NowContentU32 max_records,
                       NowQDSink sink, void *ctx,
                       NowQDDrainResult *out)
{
    NowContentU32 cap;
    NowContentU32 seq0, seq1;
    NowContentU32 wc;
    NowContentU32 avail;
    NowContentU32 budget;
    NowContentU32 consumed = 0;
    int bounded = 0;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    out->cursor = cursor;
    out->next_cursor = cursor;

    if (block == NULL) {
        out->outcome = kNowQDDrainNoBlock;
        return;
    }
    if (!block_ok(block)) {
        out->outcome = kNowQDDrainBadBlock;
        return;
    }

    /* Sample the seqlock FIRST. Odd means a commit is in flight right
       now, and the honest answer is "call again": one commit is bounded,
       and spinning here on a flag another process sets is how a
       cooperative guest stops pumping events. */
    seq0 = block->seq;
    if ((seq0 & 1u) != 0) {
        out->outcome = kNowQDDrainBusy;
        out->write_cursor = block->write_cursor;
        out->dropped = block->counters.dropped;
        return;
    }

    cap = block->ring_cap;
    wc = block->write_cursor;
    out->write_cursor = wc;
    out->dropped = block->counters.dropped;

    /* Unsigned difference, so a write_cursor that has wrapped past 2^32
       still yields the right distance. */
    avail = wc - cursor;
    if (avail > cap) {
        out->resync = 1;
        if (avail >= 0x80000000u) {
            /* Not "you fell behind by two billion bytes" - a cursor that
               is AHEAD of the writer, i.e. not from this ring (a stale
               session, a different block, a fabricated number). Reported
               as a resync with lost_bytes 0, which is a different fact
               from a measured loss and must not read as one. */
            out->lost_bytes = 0;
        } else {
            out->lost_bytes = avail - cap;
        }
        cursor = wc;
        avail = 0;
    }
    out->cursor = cursor;
    out->next_cursor = cursor;

    budget = avail;
    if (max_bytes != 0 && max_bytes < budget) {
        budget = max_bytes;
        bounded = 1;
    }

    while (consumed < budget) {
        NowContentU32 pos = (cursor + consumed) % cap;
        NowContentRecHeader h;
        NowQDRecord rec;
        NowContentU32 size;

        if (cap - pos < (NowContentU32)sizeof(NowContentRecHeader)) {
            /* The writer's tail invariant says this cannot happen. It is
               checked because the invariant is the WRITER's, and the
               writer is a separately loaded binary. */
            out->outcome = kNowQDDrainCorrupt;
            return;
        }
        copy_out(&h, &block->ring[pos], (NowContentU32)sizeof h);
        size = h.size;
        if (size < (NowContentU32)sizeof(NowContentRecHeader)
            || (size & 1u) != 0
            || size > cap
            || pos + size > cap) {
            /* Records are never wrapped mid-record, so one that runs off
               the ring's end is not a record. */
            out->outcome = kNowQDDrainCorrupt;
            return;
        }
        if (consumed + size > budget) {
            if (bounded) {
                out->more = 1;
                break;
            }
            /* Not bounded: the record claims to extend past write_cursor,
               and seq says no commit is in flight. Nothing legal produces
               that. */
            out->outcome = kNowQDDrainCorrupt;
            return;
        }

        if (h.op == (unsigned char)kNowContentOpWrap) {
            consumed += size;
            out->wraps++;
            continue;
        }

        memset(&rec, 0, sizeof rec);
        rec.op = h.op;
        rec.flags = h.flags;
        rec.port = h.port;
        rec.ticks = h.ticks;
        rec.a5 = h.a5;
        rec.psn_hi = h.psn_hi;
        rec.psn_lo = h.psn_lo;
        rec.display_epoch = h.display_epoch;
        rec.generation = h.generation;
        rec.size = size;
        rec.payload_ok = decode_payload(
            &rec, &block->ring[pos + sizeof(NowContentRecHeader)],
            size - (NowContentU32)sizeof(NowContentRecHeader));

        if (sink != NULL && !sink(ctx, &rec)) {
            /* The consumer's output filled. The record is NOT counted and
               the cursor does NOT advance past it, so the next drain
               re-reads it whole. */
            out->more = 1;
            break;
        }
        consumed += size;
        out->records++;
        if (max_records != 0 && out->records >= max_records) {
            if (consumed < budget || bounded) {
                out->more = 1;
            }
            break;
        }
    }
    if (bounded && consumed >= budget && out->more == 0 && avail > budget) {
        out->more = 1;
    }

    out->next_cursor = cursor + consumed;
    out->pending = wc - out->next_cursor;

    /* Re-sample. Unchanged means no writer touched the ring for the whole
       walk and the decode stands. Changed means a writer committed while
       we walked, which only invalidates what we read if it LAPPED the
       window - decidable exactly, from the distance the writer has now
       travelled since our start. A torn read is DISCARDED rather than
       shipped: half a walk over bytes that were rewritten underneath it
       is the plausible-garbage case this whole file is written against. */
    seq1 = block->seq;
    if (seq1 != seq0) {
        NowContentU32 wc2 = block->write_cursor;
        if (wc2 - cursor > cap) {
            out->outcome = kNowQDDrainTorn;
            out->records = 0;
            out->more = 0;
            out->next_cursor = wc2;
            out->pending = 0;
            out->resync = 1;
            return;
        }
    }
    out->outcome = kNowQDDrainOk;
}

/* ---- status --------------------------------------------------------- */

void now_qdtrace_status(const NowContentBlock *block,
                        NowContentU32 cursor,
                        NowQDStatus *out)
{
    NowContentU32 avail;

    if (out == NULL) {
        return;
    }
    memset(out, 0, sizeof *out);
    if (block == NULL) {
        out->outcome = kNowQDDrainNoBlock;
        return;
    }
    if (!block_ok(block)) {
        out->outcome = kNowQDDrainBadBlock;
        /* Format and length are reported even when they are the reason
           for the refusal - a version mismatch a caller cannot see the
           numbers of is a support call. */
        out->format = block->format;
        out->length = block->length;
        out->ring_cap = block->ring_cap;
        return;
    }
    out->outcome = kNowQDDrainOk;
    out->format = block->format;
    out->length = block->length;
    out->ring_cap = block->ring_cap;
    out->write_cursor = block->write_cursor;
    out->seq = block->seq;
    out->committing = (int)(block->seq & 1u);
    out->ticks = block->ticks;

    out->active_a5 = block->active_a5;
    out->active_mode = block->active_mode;
    out->hooked_ports = block->hooked_ports;
    out->active_window = block->active_window;
    out->active_psn_hi = block->active_psn_hi;
    out->active_psn_lo = block->active_psn_lo;
    out->active_generation = block->active_generation;
    out->display_epoch = block->display_epoch;
    out->redraw_requested_generation = block->redraw_requested_generation;
    out->redraw_serviced_generation = block->redraw_serviced_generation;
    out->redraw_requests = block->redraw_requests;
    out->redraw_services = block->redraw_services;

    out->arm_a5 = block->arm_a5;
    out->arm_expiry = block->arm_expiry;
    out->arm_mode = block->mode;
    out->arm_window = block->arm_window;
    out->arm_psn_hi = block->arm_psn_hi;
    out->arm_psn_lo = block->arm_psn_lo;
    out->arm_generation = block->arm_generation;
    out->arm_committed =
        (block->arm_commit == (NowContentU32)kNowContentArmCommit) ? 1 : 0;

    avail = block->write_cursor - cursor;
    if (avail > block->ring_cap) {
        out->overrun = 1;
        out->pending = block->ring_cap;
        out->lost_bytes = (avail >= 0x80000000u) ? 0 : avail - block->ring_cap;
    } else {
        out->pending = avail;
    }

    out->counters = block->counters;

    /* The probe fields are an accretive append; the length gate is the
       whole compatibility story, same as the v2 fields' own rule. */
    if (block->length >= (NowContentU32)(offsetof(NowContentBlock,
                                                  probe_sight_small)
                                         + sizeof(NowContentU32))) {
        out->has_probe = 1;
        out->probe_pending_pixmap = block->probe_pending_pixmap;
        out->probe_pixmaps_seen = block->probe_pixmaps_seen;
        out->probe_scans = block->probe_scans;
        out->probe_hits = block->probe_hits;
        out->probe_misses = block->probe_misses;
        out->probe_offscreen_ports = block->probe_offscreen_ports;
        out->probe_stale_rows = block->probe_stale_rows;
        out->probe_last_match = block->probe_last_match;
        out->probe_already_ours = block->probe_already_ours;
        out->probe_base_candidates = block->probe_base_candidates;
        out->probe_first_candidate = block->probe_first_candidate;
        out->probe_cand_l = block->probe_cand_l;
        out->probe_cand_t = block->probe_cand_t;
        out->probe_cand_r = block->probe_cand_r;
        out->probe_cand_b = block->probe_cand_b;
        out->probe_sight_offers = block->probe_sight_offers;
        out->probe_sight_busy = block->probe_sight_busy;
        out->probe_sight_seen = block->probe_sight_seen;
        out->probe_last_sight = block->probe_last_sight;
        out->probe_sight_l = block->probe_sight_l;
        out->probe_sight_t = block->probe_sight_t;
        out->probe_sight_r = block->probe_sight_r;
        out->probe_sight_b = block->probe_sight_b;
        out->probe_sight_small = block->probe_sight_small;
    }
}

/* ---- arming --------------------------------------------------------- */

int now_qdtrace_arm_plan(const char *mode_str,
                         NowContentU32 a5,
                         NowContentU32 window,
                         NowContentU32 psn_hi,
                         NowContentU32 psn_lo,
                         NowContentU32 generation,
                         long ttl_ticks,
                         NowContentU32 now_ticks,
                         NowQDArmPlan *out)
{
    NowContentU32 mode;

    if (out == NULL) {
        return kNowQDArmNoTarget;
    }
    out->a5 = 0;
    out->expiry = 0;
    out->mode = (NowContentU32)kNowContentModeOff;
    out->window = 0;
    out->psn_hi = 0;
    out->psn_lo = 0;
    out->generation = 0;

    if (mode_str == NULL || mode_str[0] == '\0'
        || strcmp(mode_str, "count") == 0) {
        mode = (NowContentU32)kNowContentModeCount;
    } else if (strcmp(mode_str, "record") == 0) {
        mode = (NowContentU32)kNowContentModeRecord;
    } else if (strcmp(mode_str, "probe") == 0) {
        mode = (NowContentU32)kNowContentModeProbe;
    } else {
        return kNowQDArmBadMode;
    }

    /* Refused at the near end rather than written and refused by the
       extension. Zero is the value a caller reaches for when they mean
       "everything", and the plane reads it as "nothing"; telling them no
       here is the difference between a refusal and a silence. */
    if (a5 == 0 || window == 0 || generation == 0) {
        return kNowQDArmNoTarget;
    }

    if (ttl_ticks == 0) {
        ttl_ticks = (long)kNowQDTtlDefault;
    }
    if (ttl_ticks < (long)kNowQDTtlMin || ttl_ticks > (long)kNowQDTtlMax) {
        return kNowQDArmBadTtl;
    }

    out->a5 = a5;
    out->mode = mode;
    out->window = window;
    out->psn_hi = psn_hi;
    out->psn_lo = psn_lo;
    out->generation = generation;
    out->expiry = now_ticks + (NowContentU32)ttl_ticks;
    /* An expiry of exactly 0 is "expired on sight" in the contract, and
       TickCount wrap can land there. One tick later is not a meaningful
       difference in duration and is the difference between a request and
       a no-op. */
    if (out->expiry == 0) {
        out->expiry = 1;
    }
    return kNowQDArmOk;
}

/* THE ORDER IS THE CONTRACT. arm_a5, arm_expiry and mode first;
   arm_commit LAST. A jGNE pass runs between arbitrary stores, and this
   order is what makes it impossible for a live commit word to be paired
   with the previous request's target. Do not reorder these four lines,
   and do not let a compiler do it either - each store is to a volatile
   view of memory another processor context reads.

   qdtrace_arm_order_source_test.py reads this function as text and fails
   if arm_commit moves. A test that observes only the end state cannot
   see an ordering, so the ordering is gated where it is legible. */
void now_qdtrace_arm_commit(NowContentBlock *block, const NowQDArmPlan *plan)
{
    volatile NowContentBlock *b = (volatile NowContentBlock *)block;

    if (block == NULL || plan == NULL) {
        return;
    }
    /* Retarget is itself a disarm/rearm. Clear the old permission before
       changing any identity word, or a resident pass between stores can
       observe the old commit paired with a mixed request. */
    b->arm_commit = 0;
    __asm__ volatile("" ::: "memory");
    b->arm_a5 = plan->a5;
    b->arm_expiry = plan->expiry;
    b->mode = plan->mode;
    b->arm_window = plan->window;
    b->arm_psn_hi = plan->psn_hi;
    b->arm_psn_lo = plan->psn_lo;
    b->arm_generation = plan->generation;
    __asm__ volatile("" ::: "memory");
    b->arm_commit = (NowContentU32)kNowContentArmCommit;
}

/* Backwards, for the same reason: clearing the commit word first means
   no jGNE pass can ever see permission attached to a target that has
   already been cleared. The target and deadline are cleared after it so
   a stale a5 cannot be re-armed by a later commit word alone. */
void now_qdtrace_disarm(NowContentBlock *block)
{
    volatile NowContentBlock *b = (volatile NowContentBlock *)block;

    if (block == NULL) {
        return;
    }
    b->arm_commit = 0;
    b->mode = (NowContentU32)kNowContentModeOff;
    b->arm_expiry = 0;
    b->arm_a5 = 0;
    b->arm_window = 0;
    b->arm_psn_hi = 0;
    b->arm_psn_lo = 0;
    b->arm_generation = 0;
}
