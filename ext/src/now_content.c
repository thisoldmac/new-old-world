/*
 * now_content.c - the content plane (P3): QuickDraw bottleneck hooks.
 *
 * This is the riskiest code in the product. It runs at DRAW time, inside
 * whatever application is drawing, and a fault here takes the machine
 * rather than a window. docs/resident-components.md classifies it and
 * fences it: dark until armed, armed per-target and per-port within it, a
 * separate failure domain in everything but the file.
 *
 * THE MECHANISM, and where it comes from. Every QuickDraw drawing call
 * funnels through its port's bottleneck procedures. The plane installs a
 * custom CQDProcs on an armed application's window ports; each hook bumps
 * a counter, optionally records the operation, then calls the standard
 * proc so the drawing still happens. Scoped through per-port grafProcs -
 * not a screen tap.
 *
 * Ported from this project's own prototype (timbottu/mirror,
 * guest/extensions/qdpeek, mirror/docs/QDPEEK-SPEC.md), which measured it
 * on a live mac99 guest: the ten families, the re-entrancy guard, the
 * install/uninstall/repair state machine, and the counters are upstream's
 * and are kept exactly. The header rule of now-guest-ppc/src/axwalk/
 * governs the crossing: THE MEASURED PARTS ARE EVIDENCE, NOT STYLE.
 * Upstream's proof is strong evidence about the mechanism and is NOT a
 * measurement of this binary. Nothing in this file has run on a Macintosh.
 *
 * THREE THINGS THIS PORT DOES DIFFERENTLY, each because NOW's conventions
 * differ rather than because upstream was wrong:
 *
 *   1. IDENTITY IS A5, NOT A PSN. Upstream keyed ownership on a
 *      ProcessSerialNumber and called the Process Manager from the filter
 *      to age rows out. NOW's resident code reads low memory and nothing
 *      else (the anchor plane's rule, docs/resident-components.md), and
 *      LMGetCurrentA5 is one low-memory read from any context. The arm
 *      request names an A5 world for the same reason. The cost is stated
 *      below where it bites.
 *   2. ARMING NAMES ITS TARGET. Upstream's command block asked for a mode
 *      and a process; this one refuses a request that names no target
 *      rather than reading it as "all", and refuses one that names a
 *      different context than the one reading it. That verdict is in
 *      now_content_logic.c so it can be tested.
 *   3. NO RESIDENT LOGGING. Upstream's INIT wrote a boot log to the root
 *      volume. Logging is never resident here; the counters are the
 *      instrument.
 */

#include <Events.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <OSUtils.h>
#include <QuickDraw.h>

#include "content_table.h"

#include <string.h>

/* Port layout, pinned. GrafPort and CGrafPort are the same SIZE and
   different layouts, which is exactly why the discriminator below is
   checked before anything touches grafProcs. */
_Static_assert(sizeof(GrafPort) == 108, "unexpected GrafPort layout");
_Static_assert(sizeof(CGrafPort) == 108, "unexpected CGrafPort layout");
_Static_assert(offsetof(CGrafPort, portVersion) == 6,
               "unexpected CGrafPort discriminator");

/* ---- resident state -------------------------------------------------
   All of it lives in the relocated flat blob, which is sysHeap + locked +
   detached and therefore never moves; these absolute addresses are valid
   from any later context, which is why the extension never calls
   Retro68FreeGlobals. */

static NowContentBlock *gBlock = NULL;

/* The A5 world we are armed on, or 0. Written only by the GNE applier,
   read by every hook. A hook that finds it 0, or finds it different from
   the context it is running in, is strict pass-through. */
static NowPeekU32 gArmedA5 = 0;
static NowPeekU32 gArmedMode = kNowContentModeOff;

/* THE RE-ENTRANCY GUARD, and it is not the ring's drop counter - the two
   are conflated constantly and are different things. A bottleneck's
   standard proc calls OTHER bottlenecks: StdText blits each glyph through
   StdBits. This flag makes a hook record only the TOP-LEVEL entry and pass
   nested calls straight through. Nested ops are intentional noise, not
   lost data, so nothing is counted as dropped here. Upstream measured it
   airtight (a 41-character run recorded text=41, bits=0). Classic Mac OS
   draws one thing at a time, so one resident flag suffices. */
static short gInCapture = 0;

/* The standard bottlenecks, and our record: a copy of the standard set
   with the ten families we track overridden. Every hook tail-calls
   through gStd, NOT through the port's previous grafProcs - see
   now_content_chain_is_sound(). */
static CQDProcs gStd;
static CQDProcs gHooks;

/* Per-port install table. `prev` is the port's grafProcs as we found it;
   `a5` is the context we patched from, and a restore is attempted ONLY
   from that same context (rule 2 of prototypes/qdprobe's dangerous-part
   list, which this plane inherits). */
static struct {
    GrafPtr port;
    CQDProcsPtr prev;
    NowPeekU32 a5;
    NowPeekU32 generation;
    short redraw_requested;
    short shadow_valid;
    /* The GWorld probe's rows. `offscreen` marks a port that is NOT on
       any WindowList - the liveness rules that govern window rows would
       evict it on the first repair sweep - and `pixmap` is the
       PixMapHandle that identified it, re-checked before every
       dereference because a DisposeGWorld is invisible from here. */
    short offscreen;
    NowPeekU32 pixmap;
    NowContentPortState shadow;
} gPorts[kNowContentMaxPorts];
static short gPortCount = 0;

/* Every source pixmap the probe has already chased, hit or miss, so one
   GWorld blitting sixty times a minute costs one zone scan, not sixty.
   Reset when the armed identity changes. */
#define kNowContentProbeSeenMax 16
static NowPeekU32 gProbeSeen[kNowContentProbeSeenMax];
static short gProbeSeenCount = 0;

/* Cheap change-detect for the repair sweep, so a 33 MHz machine is not
   charged a WindowList walk on every single event-loop pass. */
static NowPeekU32 gLastWindowList = 0;
static NowPeekU32 gLastRepairTicks = 0;

/* ---- recording ------------------------------------------------------ */

/* LMGetTicks(), not TickCount(): this runs at draw time inside another
   process's context, and the low-memory global is the read this plane's
   other resident code already relies on (content_capture_enabled below
   calls LMGetCurrentA5() the same way) - no trap dispatch, no allocation.

   Called on EVERY top-level hook entry, record mode or count mode alike.
   It used to run only on the count-mode branch, which left `ticks`
   holding whatever it was at arm time for the whole life of a Record
   session: now_content_ring_put stamps each record from this field
   (content_table.h's "TickCount at capture"), so a caller that does not
   refresh it before a record is committed hands every record the SAME
   stale stamp - measured on a real drain: 19 records, ticks all 1735,
   equal to the block's own liveness field and unchanged across a second
   armed cycle. SceneIslands orders redraws by this field, so a frozen
   stamp cannot tell two later blits apart. */
static void content_stamp(void)
{
    if (gBlock != NULL) {
        gBlock->ticks = (NowPeekU32)LMGetTicks();
    }
}

static short content_slot_for(GrafPtr port, NowPeekU32 a5);

/* Record mode and probe mode both append ring records; count mode only
   counts. One place says so, because the ten hooks each ask. */
static Boolean content_mode_records(void)
{
    return gArmedMode == (NowPeekU32)kNowContentModeRecord
        || gArmedMode == (NowPeekU32)kNowContentModeProbe;
}

/* Armed, in the armed context, with a mode that records or counts. Every
   hook asks this first; it is the gate that makes a hook left behind on
   some other application's port a strict pass-through. */
static Boolean content_capture_enabled(void)
{
    GrafPtr port = NULL;

    if (gBlock == NULL
        || gArmedA5 == 0
        || gArmedMode == kNowContentModeOff
        || (NowPeekU32)LMGetCurrentA5() != gArmedA5) {
        return false;
    }
    GetPort(&port);
    if (port == NULL) {
        return false;
    }
    if ((NowPeekU32)port != gBlock->active_window) {
        /* THE PROBE'S ONE RELAXATION of the capture gate, and its exact
           shape matters: an op drawn into an offscreen GWorld arrives
           with the GWorld as the current port, which is never the armed
           window - the reason the plane has recorded zero ops for every
           composite ever built. In probe mode, a port records iff WE
           hooked it as an offscreen row for this same armed context.
           Any other port - another window, another app's port a hook
           was left on - stays strict pass-through, exactly as before. */
        short slot;

        if (gArmedMode != (NowPeekU32)kNowContentModeProbe) {
            return false;
        }
        slot = content_slot_for(port, gArmedA5);
        return slot >= 0 && gPorts[slot].offscreen;
    }
    if (gBlock->redraw_requested_generation == gBlock->active_generation
        && gBlock->redraw_serviced_generation != gBlock->active_generation) {
        gBlock->redraw_serviced_generation = gBlock->active_generation;
        gBlock->redraw_services++;
    }
    return true;
}

/* Read one port's live drawing state into the pure comparison's shape.
   The only Toolbox reads in the state path; the DECISION about what
   changed is now_content_state_deltas, which a host cc runs. */
static void content_read_state(GrafPtr port, NowContentPortState *out)
{
    RGBColor fg;
    RGBColor bg;
    Rect clip;

    out->origin_h = port->portRect.left;
    out->origin_v = port->portRect.top;
    if (port->clipRgn != NULL && *port->clipRgn != NULL) {
        clip = (**port->clipRgn).rgnBBox;
    } else {
        clip = port->portRect;
    }
    out->clip_l = clip.left;
    out->clip_t = clip.top;
    out->clip_r = clip.right;
    out->clip_b = clip.bottom;
    fg = ((CGrafPtr)port)->rgbFgColor;
    bg = ((CGrafPtr)port)->rgbBkColor;
    out->fg_r = fg.red; out->fg_g = fg.green; out->fg_b = fg.blue;
    out->bg_r = bg.red; out->bg_g = bg.green; out->bg_b = bg.blue;
}

static short content_slot_for(GrafPtr port, NowPeekU32 a5)
{
    short i;

    for (i = 0; i < gPortCount; ++i) {
        if (gPorts[i].port == port && gPorts[i].a5 == a5) {
            return i;
        }
    }
    return -1;
}

/* Emit the STATE records this port needs before its next op, and commit
   the shadow only for the ones that actually landed - a dropped record
   must never leave the shadow claiming the host saw a state it did not. */
static void content_emit_state(GrafPtr port)
{
    NowContentPortState live;
    NowContentStatePayload pl;
    NowPeekU32 deltas;
    short slot = content_slot_for(port, (NowPeekU32)LMGetCurrentA5());

    if (slot < 0) {
        return;
    }
    content_read_state(port, &live);
    deltas = now_content_state_deltas(&gPorts[slot].shadow,
                                      gPorts[slot].shadow_valid, &live);
    if (deltas == 0) {
        return;
    }
    pl.pad = 0;
    pl.d = 0; pl.e = 0; pl.f = 0;

    if ((deltas & kNowContentDeltaOrigin) != 0) {
        pl.kind = kNowContentStateOrigin;
        pl.a = live.origin_h; pl.b = live.origin_v; pl.c = 0;
        if (now_content_ring_put(gBlock, kNowContentOpState, 0,
                                 (NowPeekU32)port, &pl, sizeof(pl))) {
            gPorts[slot].shadow.origin_h = live.origin_h;
            gPorts[slot].shadow.origin_v = live.origin_v;
        }
    }
    if ((deltas & kNowContentDeltaClip) != 0) {
        pl.kind = kNowContentStateClip;
        pl.a = live.clip_l; pl.b = live.clip_t;
        pl.c = live.clip_r; pl.d = live.clip_b;
        if (now_content_ring_put(gBlock, kNowContentOpState, 0,
                                 (NowPeekU32)port, &pl, sizeof(pl))) {
            gPorts[slot].shadow.clip_l = live.clip_l;
            gPorts[slot].shadow.clip_t = live.clip_t;
            gPorts[slot].shadow.clip_r = live.clip_r;
            gPorts[slot].shadow.clip_b = live.clip_b;
        }
        pl.d = 0;
    }
    if ((deltas & kNowContentDeltaFg) != 0) {
        pl.kind = kNowContentStateFg;
        pl.a = (NowContentS16)live.fg_r;
        pl.b = (NowContentS16)live.fg_g;
        pl.c = (NowContentS16)live.fg_b;
        if (now_content_ring_put(gBlock, kNowContentOpState, 0,
                                 (NowPeekU32)port, &pl, sizeof(pl))) {
            gPorts[slot].shadow.fg_r = live.fg_r;
            gPorts[slot].shadow.fg_g = live.fg_g;
            gPorts[slot].shadow.fg_b = live.fg_b;
        }
    }
    if ((deltas & kNowContentDeltaBg) != 0) {
        pl.kind = kNowContentStateBg;
        pl.a = (NowContentS16)live.bg_r;
        pl.b = (NowContentS16)live.bg_g;
        pl.c = (NowContentS16)live.bg_b;
        if (now_content_ring_put(gBlock, kNowContentOpState, 0,
                                 (NowPeekU32)port, &pl, sizeof(pl))) {
            gPorts[slot].shadow.bg_r = live.bg_r;
            gPorts[slot].shadow.bg_g = live.bg_g;
            gPorts[slot].shadow.bg_b = live.bg_b;
        }
    }
    /* Valid only once a full set has been offered; the first pass emits
       all four by definition, so this is the moment the shadow becomes
       a comparison rather than a placeholder. */
    gPorts[slot].shadow_valid = 1;
}

/* THE JACKPOT: a drawn text run, with the port's pen and text state, so
   the host replays it through the matching strike instead of a bitmap. */
static void content_record_text(short byte_count, const void *text_buf)
{
    NowContentTextPayload pl;
    unsigned char rec[sizeof(NowContentTextPayload) + kNowContentTextMax];
    GrafPtr port = NULL;
    NowContentU16 inline_len;
    NowContentU16 i;

    GetPort(&port);
    if (port == NULL) {
        return;
    }
    content_emit_state(port);

    if (byte_count < 0) {
        byte_count = 0;
    }
    inline_len = (byte_count > kNowContentTextMax)
        ? (NowContentU16)kNowContentTextMax : (NowContentU16)byte_count;

    pl.pen_h = port->pnLoc.h;
    pl.pen_v = port->pnLoc.v;
    pl.tx_font = (NowContentU16)port->txFont;
    pl.tx_size = (NowContentU16)port->txSize;
    pl.tx_face = (unsigned char)port->txFace;
    pl.len = (unsigned char)inline_len;
    pl.full_len = (NowContentU16)byte_count;

    for (i = 0; i < sizeof(pl); ++i) {
        rec[i] = ((const unsigned char *)&pl)[i];
    }
    for (i = 0; i < inline_len && text_buf != NULL; ++i) {
        rec[sizeof(pl) + i] = ((const unsigned char *)text_buf)[i];
    }
    (void)now_content_ring_put(gBlock, kNowContentOpText,
                               (byte_count > kNowContentTextMax)
                                   ? kNowContentFlagTruncText : 0,
                               (NowPeekU32)port, rec,
                               (NowContentU16)(sizeof(pl) + inline_len));
}

static void content_record_line(Point new_pt)
{
    NowContentLinePayload pl;
    GrafPtr port = NULL;

    GetPort(&port);
    if (port == NULL) {
        return;
    }
    content_emit_state(port);
    pl.from_h = port->pnLoc.h;
    pl.from_v = port->pnLoc.v;
    pl.to_h = new_pt.h;
    pl.to_v = new_pt.v;
    pl.pn_h = port->pnSize.h;
    pl.pn_v = port->pnSize.v;
    (void)now_content_ring_put(gBlock, kNowContentOpLine, 0,
                               (NowPeekU32)port, &pl, sizeof(pl));
}

/* RECT / RRECT / OVAL / ARC, and POLY / RGN with the bounding box in
   place of the rect - never the point or region data. */
static void content_record_rectlike(unsigned char op, GrafVerb verb,
                                    const Rect *r, short ext1, short ext2)
{
    NowContentRectPayload pl;
    GrafPtr port = NULL;

    GetPort(&port);
    if (port == NULL || r == NULL) {
        return;
    }
    content_emit_state(port);
    pl.verb = (unsigned char)verb;
    pl.pad = 0;
    pl.l = r->left; pl.t = r->top; pl.r = r->right; pl.b = r->bottom;
    pl.ext1 = ext1; pl.ext2 = ext2;
    (void)now_content_ring_put(gBlock, op, 0, (NowPeekU32)port,
                               &pl, sizeof(pl));
}

/* Geometry only, NEVER pixels. The host composes real pixels for the dst
   rect through its own island path when it needs them. */
static void content_record_bits(const BitMap *src_bits, const Rect *src_rect,
                                const Rect *dst_rect, short mode)
{
    NowContentBitsPayload pl;
    GrafPtr port = NULL;

    GetPort(&port);
    if (port == NULL || src_rect == NULL || dst_rect == NULL) {
        return;
    }
    content_emit_state(port);
    pl.sl = src_rect->left; pl.st = src_rect->top;
    pl.sr = src_rect->right; pl.sb = src_rect->bottom;
    pl.dl = dst_rect->left; pl.dt = dst_rect->top;
    pl.dr = dst_rect->right; pl.db = dst_rect->bottom;
    pl.mode = (NowContentU16)mode;
    pl.src_row_bytes = (src_bits != NULL)
        ? (NowContentU16)(src_bits->rowBytes & 0x7FFF) : 0;
    (void)now_content_ring_put(gBlock, kNowContentOpBits, 0,
                               (NowPeekU32)port, &pl, sizeof(pl));
}

/* THE PROBE'S SIGHTING, from inside the bits hook with the capture guard
   held: a blit into the armed window whose source is a PixMap we have
   not chased yet gets its source stashed for the GNE moment. Nothing is
   dereferenced beyond the BitMap the hook was handed, nothing is
   allocated, and nothing happens at all outside probe mode. The 0x8000
   rowBytes bit is Color QuickDraw's own "this BitMap is a PixMap"
   discriminator; a plain BitMap has no owning port to find. */
static void content_probe_sight(const BitMap *src_bits)
{
    GrafPtr port = NULL;
    short i;

    if (gArmedMode != (NowPeekU32)kNowContentModeProbe
        || src_bits == NULL
        || ((unsigned short)src_bits->rowBytes & 0x8000U) == 0) {
        return;
    }
    /* Only a blit INTO the armed window names a composite worth chasing.
       A blit inside a hooked GWorld (an icon stamped from a resource,
       say) is already the recorded evidence the probe wants - chasing
       its source too would walk an unbounded chain of stamps. */
    GetPort(&port);
    if (port == NULL || (NowPeekU32)port != gBlock->active_window) {
        return;
    }
    for (i = 0; i < gProbeSeenCount; ++i) {
        if (gProbeSeen[i] == (NowPeekU32)src_bits) {
            return;
        }
    }
    if (gBlock->probe_pending_pixmap != 0) {
        return;               /* one chase in flight; a later blit re-offers */
    }
    gBlock->probe_pending_pixmap = (NowPeekU32)src_bits;
    gBlock->probe_pending_l = src_bits->bounds.left;
    gBlock->probe_pending_t = src_bits->bounds.top;
    gBlock->probe_pending_r = src_bits->bounds.right;
    gBlock->probe_pending_b = src_bits->bounds.bottom;
}

/* ---- the ten hooks --------------------------------------------------
 * Every one has the same body and it is deliberately not factored: the
 * guard, the counter, the record, and the tail-call have to be visible
 * together in each, because the ONE thing that must never be got wrong is
 * that the standard proc is called on BOTH paths. A refactor that hoists
 * the tail-call is a refactor that can lose it on one branch, and losing
 * it means an armed application stops drawing.
 */

static pascal void content_text(short byteCount, const void *textBuf,
                                Point numer, Point denom)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.text++;
        content_stamp();
        if (content_mode_records()) {
            content_record_text(byteCount, textBuf);
        }
        InvokeQDTextUPP(byteCount, textBuf, numer, denom, gStd.textProc);
        gInCapture = 0;
    } else {
        InvokeQDTextUPP(byteCount, textBuf, numer, denom, gStd.textProc);
    }
}

static pascal void content_line(Point newPt)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.line++;
        content_stamp();
        if (content_mode_records()) {
            content_record_line(newPt);
        }
        InvokeQDLineUPP(newPt, gStd.lineProc);
        gInCapture = 0;
    } else {
        InvokeQDLineUPP(newPt, gStd.lineProc);
    }
}

static pascal void content_rect(GrafVerb verb, const Rect *r)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.rect++;
        content_stamp();
        if (content_mode_records()) {
            content_record_rectlike(kNowContentOpRect, verb, r, 0, 0);
        }
        InvokeQDRectUPP(verb, r, gStd.rectProc);
        gInCapture = 0;
    } else {
        InvokeQDRectUPP(verb, r, gStd.rectProc);
    }
}

static pascal void content_rrect(GrafVerb verb, const Rect *r,
                                 short ovalWidth, short ovalHeight)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.rrect++;
        content_stamp();
        if (content_mode_records()) {
            content_record_rectlike(kNowContentOpRRect, verb, r,
                                    ovalWidth, ovalHeight);
        }
        InvokeQDRRectUPP(verb, r, ovalWidth, ovalHeight, gStd.rRectProc);
        gInCapture = 0;
    } else {
        InvokeQDRRectUPP(verb, r, ovalWidth, ovalHeight, gStd.rRectProc);
    }
}

static pascal void content_oval(GrafVerb verb, const Rect *r)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.oval++;
        content_stamp();
        if (content_mode_records()) {
            content_record_rectlike(kNowContentOpOval, verb, r, 0, 0);
        }
        InvokeQDOvalUPP(verb, r, gStd.ovalProc);
        gInCapture = 0;
    } else {
        InvokeQDOvalUPP(verb, r, gStd.ovalProc);
    }
}

static pascal void content_arc(GrafVerb verb, const Rect *r,
                               short startAngle, short arcAngle)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.arc++;
        content_stamp();
        if (content_mode_records()) {
            content_record_rectlike(kNowContentOpArc, verb, r,
                                    startAngle, arcAngle);
        }
        InvokeQDArcUPP(verb, r, startAngle, arcAngle, gStd.arcProc);
        gInCapture = 0;
    } else {
        InvokeQDArcUPP(verb, r, startAngle, arcAngle, gStd.arcProc);
    }
}

static pascal void content_poly(GrafVerb verb, PolyHandle poly)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.poly++;
        content_stamp();
        if (content_mode_records() && poly != NULL
            && *poly != NULL) {
            content_record_rectlike(kNowContentOpPoly, verb,
                                    &((**poly).polyBBox), 0, 0);
        }
        InvokeQDPolyUPP(verb, poly, gStd.polyProc);
        gInCapture = 0;
    } else {
        InvokeQDPolyUPP(verb, poly, gStd.polyProc);
    }
}

static pascal void content_rgn(GrafVerb verb, RgnHandle rgn)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.rgn++;
        content_stamp();
        if (content_mode_records() && rgn != NULL
            && *rgn != NULL) {
            content_record_rectlike(kNowContentOpRgn, verb,
                                    &((**rgn).rgnBBox), 0, 0);
        }
        InvokeQDRgnUPP(verb, rgn, gStd.rgnProc);
        gInCapture = 0;
    } else {
        InvokeQDRgnUPP(verb, rgn, gStd.rgnProc);
    }
}

static pascal void content_bits(const BitMap *srcBits, const Rect *srcRect,
                                const Rect *dstRect, short mode,
                                RgnHandle maskRgn)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.bits++;
        content_stamp();
        if (content_mode_records()) {
            content_record_bits(srcBits, srcRect, dstRect, mode);
        }
        content_probe_sight(srcBits);
        InvokeQDBitsUPP(srcBits, srcRect, dstRect, mode, maskRgn,
                        gStd.bitsProc);
        gInCapture = 0;
    } else {
        InvokeQDBitsUPP(srcBits, srcRect, dstRect, mode, maskRgn,
                        gStd.bitsProc);
    }
}

static pascal void content_comment(short kind, short dataSize,
                                   Handle dataHandle)
{
    if (!gInCapture && content_capture_enabled()) {
        gInCapture = 1;
        gBlock->counters.comment++;
        content_stamp();
        InvokeQDCommentUPP(kind, dataSize, dataHandle, gStd.commentProc);
        gInCapture = 0;
    } else {
        InvokeQDCommentUPP(kind, dataSize, dataHandle, gStd.commentProc);
    }
}

/* ---- install / uninstall / repair, always in the port's own context -- */

/* The Color QuickDraw discriminator lives at this offset only in a
   CGrafPort; a classic B&W GrafPort reads something else here. NEVER
   touch grafProcs until this passes - the two structs are the same size
   and different shapes, so the field would land in the middle of
   something else. A B&W window is skipped and counted; honesty over
   coverage. */
static Boolean content_port_is_color(GrafPtr port)
{
    return port != NULL
        && (((unsigned short)((CGrafPtr)port)->portVersion & 0xC000U)
            == 0xC000U);
}

static Boolean content_port_is_live(GrafPtr port, WindowPeek head)
{
    WindowPeek w = head;
    short guard = 0;

    while (w != NULL && guard < 128) {
        if ((GrafPtr)w == port) {
            return true;
        }
        w = w->nextWindow;
        guard++;
    }
    return false;
}

/* Forget a row by VALUE. Never dereferences the port, which is the whole
   point: a row can outlive the heap its port lived in. */
static void content_forget_slot(short i)
{
    gPorts[i] = gPorts[gPortCount - 1];
    gPortCount--;
}

static void content_install_port(GrafPtr port, NowPeekU32 a5,
                                 NowPeekU32 generation)
{
    CQDProcsPtr prev;

    if (port == NULL || content_slot_for(port, a5) >= 0) {
        return;
    }
    if (gPortCount >= kNowContentMaxPorts) {
        gBlock->counters.skipped_ports++;
        return;
    }
    if (!content_port_is_color(port)) {
        gBlock->counters.skipped_ports++;
        return;
    }
    prev = ((CGrafPtr)port)->grafProcs;
    if (prev != NULL) {
        /* The application already customises its own bottlenecks.
           Chaining to procs we know nothing about is a v1 non-goal, and
           unwinding a chain we are not on top of is how this class of
           extension corrupts a machine. Leave it alone, count it. */
        gBlock->counters.skipped_ports++;
        return;
    }
    gPorts[gPortCount].port = port;
    gPorts[gPortCount].prev = prev;
    gPorts[gPortCount].a5 = a5;
    gPorts[gPortCount].generation = generation;
    gPorts[gPortCount].redraw_requested = 0;
    gPorts[gPortCount].shadow_valid = 0;
    gPorts[gPortCount].offscreen = 0;
    gPorts[gPortCount].pixmap = 0;
    gPortCount++;
    ((CGrafPtr)port)->grafProcs = &gHooks;
    gBlock->counters.installs++;
    gBlock->hooked_ports = (NowPeekU32)gPortCount;
}

static void content_install_exact_window(NowPeekU32 a5,
                                         NowPeekU32 window,
                                         NowPeekU32 generation)
{
    WindowPeek w = (WindowPeek)LMGetWindowList();
    short guard = 0;

    while (w != NULL && guard < 128) {
        if ((NowPeekU32)w == window) {
            content_install_port((GrafPtr)w, a5, generation);
            return;
        }
        w = w->nextWindow;
        guard++;
    }
}

/* Carbon's InvalWindowRect is unavailable to a flat 68K INIT. This is the
   bounded resident equivalent, used only after the caller proved exact live
   WindowList membership and that NOW still owns grafProcs. It schedules the
   application's normal update; it never enters the update loop or draws. */
static Boolean content_invalidate_window_compat(WindowPtr window)
{
    GrafPtr saved = NULL;
    Rect bounds;

    GetPort(&saved);
    if (saved == NULL) {
        return false;
    }
    SetPort((GrafPtr)window);
    bounds = ((GrafPtr)window)->portRect;
    InvalRect(&bounds);
    SetPort(saved);
    return true;
}

/* Schedule exactly one normal application-owned update. Membership is
   proven before the stored port is dereferenced. The compatibility shim
   does not draw, enter an update loop, or inject input; servicing is counted
   only when a later QuickDraw hook fires. */
static void content_request_redraw(NowPeekU32 a5, NowPeekU32 window,
                                   NowPeekU32 generation)
{
    WindowPeek head = (WindowPeek)LMGetWindowList();
    short slot = content_slot_for((GrafPtr)window, a5);
    GrafPtr port;

    if (slot < 0 || gPorts[slot].a5 != a5
        || gPorts[slot].generation != generation
        || gPorts[slot].redraw_requested
        || !content_port_is_live(gPorts[slot].port, head)) {
        return;
    }
    port = gPorts[slot].port;       /* membership proven above */
    if (!content_port_is_color(port)
        || ((CGrafPtr)port)->grafProcs != &gHooks) {
        return;                      /* no longer our hook, no redraw claim */
    }
    if (!content_invalidate_window_compat((WindowPtr)port)) {
        return;
    }
    gPorts[slot].redraw_requested = 1;
    gBlock->redraw_requested_generation = generation;
    gBlock->redraw_requests++;
}

/*
 * Restore every port we patched from THIS context, and forget the rows.
 *
 * Three rules hold the line here, and they are the ones the spike stated
 * (prototypes/qdprobe/README.md, "the dangerous part"):
 *
 *   1. Our CQDProcs record lives in the system heap, never in the patched
 *      application's - see gHooks. An application heap goes away when the
 *      application does; ours must not.
 *   2. Restore only from the patching context. `a5` is checked by the
 *      caller; reaching into a quit application's freed heap to tidy up
 *      is the crash this avoids.
 *   3. Verify before restoring. The port must still be in THIS context's
 *      WindowList, still be a colour port, and its grafProcs must still
 *      be ours. If something patched over us, we leave it and forget the
 *      row rather than unwinding a chain we are no longer on top of.
 *
 * Rule 3's honest consequence: an application that quits while armed
 * leaks its rows until they are forgotten by value below. A leaked row
 * costs a table slot; a wrong restore costs the machine.
 */
/* An offscreen row's port is on no WindowList, so its liveness has to be
   re-earned by shape before every dereference: still a colour port, and
   its portPixMap still the exact handle that identified it. A disposed
   GWorld fails one of the two - reading freed heap to CHECK is safe on
   this machine (the zone stays mapped), writing into it is not, which is
   why a failed check drops the row without a restore. */
static Boolean content_probe_row_valid(short i)
{
    GrafPtr port = gPorts[i].port;

    return port != NULL
        && gPorts[i].pixmap != 0
        && content_port_is_color(port)
        && (NowPeekU32)((CGrafPtr)port)->portPixMap == gPorts[i].pixmap;
}

static void content_probe_forget_row(short i)
{
    if (gBlock->probe_offscreen_ports > 0) {
        gBlock->probe_offscreen_ports--;
    }
    content_forget_slot(i);
}

static void content_uninstall_context(NowPeekU32 a5)
{
    WindowPeek head = (WindowPeek)LMGetWindowList();
    short i = 0;

    while (i < gPortCount) {
        NowContentLifecycleFacts facts;
        NowContentU32 actions;

        if (gPorts[i].a5 != a5) {
            i++;
            continue;
        }
        if (gPorts[i].offscreen) {
            /* The window rows' lifecycle rules are WindowList-shaped and
               cannot speak for a port that was never on one. Same three
               spike rules, restated for this shape: restore only from
               this context, only while we still own the hook, and never
               dereference a port that stopped matching its identity. */
            if (content_probe_row_valid(i)
                && ((CGrafPtr)gPorts[i].port)->grafProcs == &gHooks) {
                ((CGrafPtr)gPorts[i].port)->grafProcs = gPorts[i].prev;
                gBlock->counters.uninstalls++;
            } else {
                gBlock->probe_stale_rows++;
            }
            content_probe_forget_row(i);
            continue;
        }
        memset(&facts, 0, sizeof facts);
        facts.verdict = kNowContentVerdictIdle;
        facts.current_a5 = a5;
        facts.has_slot = 1;
        facts.slot_a5 = gPorts[i].a5;
        facts.slot_window = (NowPeekU32)gPorts[i].port;
        facts.slot_generation = gPorts[i].generation;
        facts.window_live = content_port_is_live(gPorts[i].port, head);
        if (facts.window_live) {
            facts.hook_owned = content_port_is_color(gPorts[i].port)
                && ((CGrafPtr)gPorts[i].port)->grafProcs == &gHooks;
        }
        actions = now_content_lifecycle_decide(&facts);
        if ((actions & kNowContentLifeRestore) != 0) {
            ((CGrafPtr)gPorts[i].port)->grafProcs = gPorts[i].prev;
            gBlock->counters.uninstalls++;
        }
        if ((actions & kNowContentLifeForget) != 0) {
            content_forget_slot(i);
        } else {
            i++;
        }
    }
    gBlock->hooked_ports = (NowPeekU32)gPortCount;
}

/* Prune rows whose window has closed (by WindowList membership, in the
   owning context), then pick up any new windows. Keeps coverage current
   as the application opens and closes windows without a fresh request. */
static void content_repair(NowPeekU32 a5, NowPeekU32 window,
                           NowPeekU32 generation)
{
    WindowPeek head = (WindowPeek)LMGetWindowList();
    short i = 0;

    while (i < gPortCount) {
        if (gPorts[i].a5 == a5 && gPorts[i].offscreen) {
            /* Not on any WindowList by construction; its staleness test
               is identity, not membership. */
            if (!content_probe_row_valid(i)) {
                gBlock->probe_stale_rows++;
                content_probe_forget_row(i);
            } else {
                i++;
            }
        } else if (gPorts[i].a5 == a5
                   && !content_port_is_live(gPorts[i].port, head)) {
            content_forget_slot(i);
        } else {
            i++;
        }
    }
    content_install_exact_window(a5, window, generation);
    gBlock->counters.repairs++;
    gBlock->hooked_ports = (NowPeekU32)gPortCount;
}

/* ---- the probe's chase ----------------------------------------------
 *
 * The GNE moment's half of the GWorld probe: a bits hook sighted a window
 * blit sourced from a PixMap nobody has chased, and stashed it. This runs
 * next, in the SAME armed context, where the Toolbox is safe - and goes
 * looking for the CGrafPort that owns that pixmap, because a GWorld is a
 * CGrafPort that no list anywhere will admit to holding.
 *
 * The route: RecoverHandle turns the dereferenced PixMap pointer back
 * into its PixMapHandle (the pixmap IS a handle - GetGWorldPixMap
 * returns one), then a linear scan of the application zone looks for the
 * port whose portPixMap field holds exactly that handle and whose
 * portRect equals the pixmap's bounds (the match itself is pure -
 * now_content_probe_match, and its false-positive reasoning is tested on
 * the host cc). A hit is hooked through the ordinary install path and
 * marked offscreen; a miss is counted, never guessed at. A GWorld whose
 * port lives outside the application zone - temp memory, the system heap
 * - lands in probe_misses, and that count is itself a finding.
 *
 * Cost, stated: the scan reads every even address in the app zone once
 * per UNSEEN pixmap (the seen table absorbs repeats), bounded below at
 * a whole-zone read and above by the 16 MB cap - milliseconds on the
 * emulated G4 this probe runs on, and the reason this mode is an
 * experiment rather than a shipping path.
 */
static void content_probe_service(NowPeekU32 a5, NowPeekU32 generation)
{
    Ptr pm;
    Handle h;
    THz zone;
    unsigned char *p;
    unsigned char *limit;
    NowContentS16 wl, wt, wr, wb;
    short slot;

    if (gArmedMode != (NowPeekU32)kNowContentModeProbe
        || gBlock->probe_pending_pixmap == 0) {
        return;
    }
    pm = (Ptr)gBlock->probe_pending_pixmap;
    wl = gBlock->probe_pending_l;
    wt = gBlock->probe_pending_t;
    wr = gBlock->probe_pending_r;
    wb = gBlock->probe_pending_b;
    gBlock->probe_pending_pixmap = 0;
    /* Remembered hit OR miss: a pixmap that failed to resolve once will
       fail the same way sixty times a second, and the scan is the cost
       being avoided. A full seen table stops chasing new pixmaps rather
       than forgetting old ones - honest saturation, visible as
       pixmaps_seen pinned at the cap. */
    if (gProbeSeenCount >= kNowContentProbeSeenMax) {
        return;
    }
    gProbeSeen[gProbeSeenCount++] = (NowPeekU32)pm;
    gBlock->probe_pixmaps_seen++;

    h = RecoverHandle(pm);
    if (h == NULL || (Ptr)*h != pm) {
        gBlock->probe_misses++;
        return;
    }
    zone = ApplicationZone();
    if (zone == NULL) {
        gBlock->probe_misses++;
        return;
    }
    p = (unsigned char *)&zone->heapData;
    limit = (unsigned char *)zone->bkLim;
    if (limit <= p
        || (unsigned long)(limit - p) > 0x01000000UL) {
        gBlock->probe_misses++;      /* a zone that cannot be believed */
        return;
    }
    gBlock->probe_scans++;
    limit -= sizeof(CGrafPort);
    for (; p <= limit; p += 2) {
        /* Cheap pre-filter inline; the pure match confirms. Memory
           Manager blocks are at least word-aligned, so step 2 cannot
           miss a real port's start. */
        if (*(NowPeekU32 *)(p + 2) != (NowPeekU32)h) {
            continue;
        }
        {
            CGrafPtr cand = (CGrafPtr)p;

            if (!now_content_probe_match((NowContentU32)cand->portPixMap,
                                         (NowContentU16)cand->portVersion,
                                         cand->portRect.left,
                                         cand->portRect.top,
                                         cand->portRect.right,
                                         cand->portRect.bottom,
                                         (NowContentU32)h,
                                         wl, wt, wr, wb)) {
                continue;
            }
            if (content_slot_for((GrafPtr)cand, a5) >= 0) {
                return;              /* already ours; nothing to count */
            }
            content_install_port((GrafPtr)cand, a5, generation);
            slot = content_slot_for((GrafPtr)cand, a5);
            if (slot >= 0) {
                gPorts[slot].offscreen = 1;
                gPorts[slot].pixmap = (NowPeekU32)h;
                gBlock->probe_hits++;
                gBlock->probe_offscreen_ports++;
            } else {
                /* Full table or foreign grafProcs; install said so in
                   skipped_ports, and the miss count keeps the probe's
                   own arithmetic honest. */
                gBlock->probe_misses++;
            }
            return;
        }
    }
    gBlock->probe_misses++;
}

/* ---- the GNE moment ------------------------------------------------- */

/*
 * Called from now_ext_gne_apply on every GetNextEvent / WaitNextEvent, in
 * whatever process is pumping. This is the ONLY place the plane installs
 * or removes anything, because it is the only moment we are guaranteed to
 * be in an application's own context with the Toolbox safe to call.
 *
 * The disarm asymmetry, stated because it is not fixable from in here:
 * refusing to patch anything NEW takes effect everywhere at once, since
 * every process decides it as it pumps. Removing instrumentation already
 * installed reaches a target only when that TARGET next pumps events. A
 * target that is suspended, wedged, or gone keeps its patch until it runs
 * again - or forever, which is the leaked-row case above.
 */
void now_content_gne(NowPeekTable *table)
{
    NowContentRequest req;
    NowPeekU32 a5;
    NowPeekU32 ticks;
    NowPeekU32 window_list;
    NowPeekU32 generation;
    int verdict;

    if (gBlock == NULL || table == NULL) {
        return;
    }
    a5 = (NowPeekU32)LMGetCurrentA5();
    ticks = (NowPeekU32)LMGetTicks();

    req.plane_bits = (table->writer.resident_owner_epoch != 0
                      && table->writer.resident_owner_epoch
                             == table->writer.owner_epoch)
                         ? table->arm_request
                         : 0;
    req.arm_commit = gBlock->arm_commit;
    req.arm_a5 = gBlock->arm_a5;
    req.arm_expiry = gBlock->arm_expiry;
    req.mode = gBlock->mode;
    req.arm_window = gBlock->arm_window;
    req.arm_psn_hi = gBlock->arm_psn_hi;
    req.arm_psn_lo = gBlock->arm_psn_lo;
    req.arm_generation = gBlock->arm_generation;
    verdict = now_content_arm_verdict(&req, a5, ticks);

    switch (verdict) {
    case kNowContentVerdictArmed:
        generation = gBlock->arm_generation;
        if (gArmedA5 != a5
            || gBlock->active_window != gBlock->arm_window
            || gBlock->active_generation != generation) {
            /* A new identity. Restore/forget same-context rows now. Foreign
               rows stay until THEIR owning context pumps: forgetting them
               here would make safe restoration impossible. Their hooks are
               strict pass-through because gArmedA5 already changes below. */
            content_uninstall_context(a5);
            gArmedA5 = a5;
            gBlock->counters.arms++;
            gLastWindowList = 0;      /* force the first repair */
            gProbeSeenCount = 0;      /* a new identity owes every pixmap
                                         a fresh chase */
            gBlock->probe_pending_pixmap = 0;
            gBlock->display_epoch++;
            if (gBlock->display_epoch == 0) {
                gBlock->display_epoch = 1;
            }
            gBlock->redraw_requested_generation = 0;
            gBlock->redraw_serviced_generation = 0;
        }
        gArmedMode = gBlock->mode;
        gBlock->active_a5 = a5;
        gBlock->active_mode = gArmedMode;
        gBlock->active_window = gBlock->arm_window;
        gBlock->active_psn_hi = gBlock->arm_psn_hi;
        gBlock->active_psn_lo = gBlock->arm_psn_lo;
        gBlock->active_generation = generation;
        table->arm_active |= (NowPeekU32)kNowPeekTableCapContent;

        content_install_exact_window(a5, gBlock->active_window,
                                     generation);
        content_request_redraw(a5, gBlock->active_window, generation);
        window_list = (NowPeekU32)LMGetWindowList();
        /* A WindowList head change catches opens and head closes at once;
           the half-second sweep catches non-head closes without charging
           every event-loop pass on a 33 MHz machine. Unsigned subtraction
           is TickCount-wrap safe. */
        if (window_list != gLastWindowList
            || ticks - gLastRepairTicks >= 30UL) {
            content_repair(a5, gBlock->active_window, generation);
            gLastWindowList = (NowPeekU32)LMGetWindowList();
            gLastRepairTicks = ticks;
        }
        content_probe_service(a5, generation);
        break;

    case kNowContentVerdictOtherContext:
        gBlock->counters.refused_wrong_context++;
        /* We are not the target. If this context still holds hooks from
           an earlier request, this is its turn to give them back - the
           only context that may. */
        content_uninstall_context(a5);
        break;

    case kNowContentVerdictNoTarget:
        gBlock->counters.refused_no_target++;
        gBlock->probe_pending_pixmap = 0;
        gArmedA5 = 0;
        gArmedMode = kNowContentModeOff;
        gBlock->active_a5 = 0;
        gBlock->active_mode = kNowContentModeOff;
        gBlock->active_window = 0;
        gBlock->active_generation = 0;
        content_uninstall_context(a5);
        break;

    case kNowContentVerdictExpired:
        gBlock->counters.refused_expired++;
        if (gBlock->arm_commit == (NowPeekU32)kNowContentArmCommit) {
            /* Retire the request itself, from whatever process noticed.
               The extension clears the commit word so a caller that died
               mid-request cannot leave a live one behind - which is the
               only thing the deadline is for. */
            gBlock->arm_commit = 0;
            gBlock->counters.retires++;
        }
        gArmedA5 = 0;
        gArmedMode = kNowContentModeOff;
        gBlock->active_a5 = 0;
        gBlock->active_mode = kNowContentModeOff;
        gBlock->active_window = 0;
        gBlock->active_generation = 0;
        content_uninstall_context(a5);
        break;

    default:                          /* idle */
        if (gArmedA5 != 0) {
            gArmedA5 = 0;
            gArmedMode = kNowContentModeOff;
            gBlock->active_a5 = 0;
            gBlock->active_mode = kNowContentModeOff;
            gBlock->active_window = 0;
            gBlock->active_generation = 0;
            gBlock->probe_pending_pixmap = 0;
        }
        if ((table->arm_active & (NowPeekU32)kNowPeekTableCapContent) != 0
            && gPortCount == 0) {
            table->arm_active &= ~(NowPeekU32)kNowPeekTableCapContent;
        }
        content_uninstall_context(a5);
        break;
    }
}

/* ---- boot ------------------------------------------------------------ */

/*
 * THE NO-CHAIN CHECK, and it is a real hazard rather than a formality.
 *
 * The spike patched a port's rectProc and tail-called the port's PREVIOUS
 * grafProcs - but it only ever patched ports whose grafProcs was NULL, so
 * there was never a previous proc to call, so every rect in a patched port
 * drew nothing while armed (prototypes/qdprobe/README.md records this).
 * Erases included.
 *
 * This plane cannot reach that state, and the reason is structural rather
 * than lucky: the hooks tail-call gStd, a COPY of the standard bottleneck
 * set taken from SetStdCProcs at boot - never the port's previous procs.
 * The NULL case the spike hit is exactly the case we install into, and in
 * it gStd still holds StdText / StdRect / StdBits and the drawing happens.
 *
 * What is left to check is the assumption underneath: that SetStdCProcs
 * actually filled all ten. If any came back NULL, a hook would tail-call
 * through a null UPP the first time that family was drawn - so the plane
 * refuses to exist rather than installing hooks that draw nothing or
 * worse. Boot-time, once, fail-closed.
 */
static Boolean now_content_chain_is_sound(void)
{
    return gStd.textProc != NULL && gStd.lineProc != NULL
        && gStd.rectProc != NULL && gStd.rRectProc != NULL
        && gStd.ovalProc != NULL && gStd.arcProc != NULL
        && gStd.polyProc != NULL && gStd.rgnProc != NULL
        && gStd.bitsProc != NULL && gStd.commentProc != NULL;
}

/*
 * Called from _start once the shared table exists and BEFORE the jGNE
 * filter is chained, so the plane is either wholly ready or wholly absent
 * the first time the filter can run.
 *
 * The block is allocated here rather than at arm time on purpose: arming
 * happens in the jGNE filter, inside a foreign process, and allocating
 * there would be a Memory Manager call on the one path the charter says
 * must never allocate. The honest cost of that choice is that the block
 * is resident whether or not anyone ever arms the plane - about 64 KiB of
 * system heap. Failure to get it is not fatal: the capability bit stays
 * clear and the product degrades to no content plane, which is the state
 * every machine is in today.
 */
void now_content_boot(NowPeekTable *table)
{
    NowContentBlock *block;

    if (table == NULL) {
        return;
    }
    SetStdCProcs(&gStd);
    if (!now_content_chain_is_sound()) {
        return;                       /* no standard procs, no plane */
    }
    gHooks = gStd;
    gHooks.textProc = NewQDTextUPP(content_text);
    gHooks.lineProc = NewQDLineUPP(content_line);
    gHooks.rectProc = NewQDRectUPP(content_rect);
    gHooks.rRectProc = NewQDRRectUPP(content_rrect);
    gHooks.ovalProc = NewQDOvalUPP(content_oval);
    gHooks.arcProc = NewQDArcUPP(content_arc);
    gHooks.polyProc = NewQDPolyUPP(content_poly);
    gHooks.rgnProc = NewQDRgnUPP(content_rgn);
    gHooks.bitsProc = NewQDBitsUPP(content_bits);
    gHooks.commentProc = NewQDCommentUPP(content_comment);

    /*
     * THE ALLOCATION IS UNCONDITIONAL, AND THAT IS NOT A STYLE CHOICE.
     *
     * The first draft of this file only assigned gBlock inside the
     * publication branch below, so in a build without the table field
     * gBlock was provably NULL to the compiler - and -Os duly deleted
     * every hook body it guards. The object file showed each of the ten
     * hooks compiled down to a bare tail-call to the standard proc: no
     * re-entrancy guard, no counter, no gate. It built clean, it linked,
     * the symbols were all present at the right sizes, and the plane was
     * hollow.
     *
     * A plane that is dark because nothing armed it and a plane that is
     * dark because the optimiser removed it look identical from outside
     * and are not the same thing - the second cannot be armed by fixing
     * the table, only by rebuilding. So the block is always allocated and
     * gBlock is always written; only PUBLISHING its address is
     * conditional, which leaves the code real and the plane merely
     * undiscoverable in the transitional build.
     */
    block = (NowContentBlock *)NewPtrSysClear((Size)sizeof(NowContentBlock));
    if (block == NULL) {
        return;                       /* degrade to absent, honestly */
    }
    block->format = kNowContentFormatV2;
    block->reserved = 0;
    block->length = (NowPeekU32)sizeof(NowContentBlock);
    block->ring_cap = (NowPeekU32)kNowContentRingCap;
    block->ticks = (NowPeekU32)LMGetTicks();
    /* Magic last, the table's own rule: a reader that somehow sees the
       address early finds it only once the block is fully formed. */
    block->magic = (NowPeekU32)kNowContentBlockMagic;
    gBlock = block;

#ifdef NOW_PEEK_TABLE_HAS_CAP_CONTENT
    /* Publish, and only then advertise. A capability bit whose block the
       application cannot find would be a lie in the one place the product
       reads to decide what it can do. */
    table->content_block = (NowPeekU32)block;
    table->caps |= (NowPeekU32)kNowPeekTableCapContent;
#endif
    /* Without the two additions contract/content_table.h asks for, the
       block exists and nothing can reach it: the capability bit stays
       clear, so the application never sets the arm bit, so every verdict
       is idle and no port is ever touched. Dark by discovery rather than
       dark by deletion - which is the distinction the comment above is
       about. */
}
