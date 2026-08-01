/*
 * qdpeek.c - TBT QDPeek: a resident INIT that captures a chosen app's
 * QuickDraw operations, the content plane the semantic AXPeek tree can't see
 * (QDPEEK-SPEC.md, QUICKDRAW-CONTENT-PLANE.md).
 *
 * Mechanism (the Timbuktu move, verified against its patents): every QuickDraw
 * drawing call funnels through its port's bottleneck procedures. QDPeek installs
 * a custom CQDProcs on the traced app's window ports; each hook bumps a counter
 * (M0) or records an op (M1), then tail-calls the standard proc so drawing
 * still happens. Scoped to chosen windows via per-port grafProcs — not a global
 * screen tap.
 *
 * Sibling to AXPeek, deliberately isolated: a draw-time hook is the riskiest
 * resident code we ship, and must not share a failure domain with the semantic
 * plane. Own GNE filter (chained), own Gestalt selector ('TBqd'), own buffer.
 *
 * M0 = count mode only: prove install / uninstall / repair / chaining and
 * measure op rates. The ring is declared but unwritten until M1.
 *
 * Re-entrancy guard (the one subtlety Timbuktu documents): a bottleneck's
 * standard proc calls OTHER bottlenecks (StdText blits each glyph via StdBits).
 * gInCapture makes hooks record only the top-level entry and pass nested calls
 * straight through. Classic Mac OS draws one thing at a time, so a single
 * resident flag suffices.
 *
 * Metal remains attended and exact-revision/hash gated after the M4 emulator
 * safety review (qdpeek-m4-metal-safety). A bug here executes inside every
 * drawing app and can crash the whole machine.
 */

#include <Events.h>
#include <Files.h>
#include <Gestalt.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <MacWindows.h>
#include <OSUtils.h>
#include <Processes.h>
#include <QuickDraw.h>
#include <Resources.h>
#include <Retro68Runtime.h>

#include "qdshared.h"

extern void qd_gne_filter(void);

_Static_assert(sizeof(GrafPort) == 108, "unexpected GrafPort layout");
_Static_assert(sizeof(CGrafPort) == 108, "unexpected CGrafPort layout");
_Static_assert(offsetof(CGrafPort, portVersion) == 6,
               "unexpected CGrafPort discriminator");

/* Chained filter (tail-called after our work), and the AXPeek-style cheap
 * change-detect anchors the assembly hot path reads. */
GetNextEventFilterUPP gOldGNEFilter = NULL;
unsigned long gLastA5 = 0;
unsigned long gLastWindowList = 0;
unsigned long gLastTicks = 0;

/* Resident state (in the relocated flat blob; absolute addresses, valid from
 * any context — the 'INIT' resource is sysHeap+locked+detached so it never
 * moves; we never call Retro68FreeGlobals). */
static QDShared *gBuf = NULL;
static unsigned long gTracedA5 = 0;     /* the traced app's A5 (cheap gate)  */
static short gInCapture = 0;            /* re-entrancy guard (top-level only)*/
static ProcessSerialNumber gActivePSN = { 0, kNoProcess };

static CQDProcs gStd;                   /* the standard bottlenecks (saved)  */
static CQDProcs gHooks;                 /* our record: std with 10 overrides */

/* Per-port install table: which ports we hooked, their previous grafProcs
 * (NULL for a normal window), and the last-recorded drawing state (the M2b
 * shadow — a STATE delta is emitted before an op when the live port differs).
 * Resident. */
static struct {
    GrafPtr      port;
    CQDProcsPtr  prev;
    ProcessSerialNumber owner;   /* heap/context that owns this port          */
    Boolean      stValid;        /* shadow populated (else force all deltas)   */
    Rect         stClip;
    Point        stOrigin;
    RGBColor     stFg;
    RGBColor     stBg;
} gInstalled[QD_TABLE_MAX];
static short gInstalledCount = 0;

/* ---- boot log (axpeek pattern) ------------------------------------------- */
static short g_lref = 0, g_lvref = 0;

static void log_open(void)
{
    FSSpec spec;
    if (GetVol(NULL, &g_lvref) != noErr) { g_lvref = 0; }
    if (FSMakeFSSpec(g_lvref, fsRtDirID, "\ptbt-qdpeek.txt", &spec) == noErr) {
        (void)FSpDelete(&spec);
    }
    if (FSpCreate(&spec, 'ttxt', 'TEXT', 0) != noErr) { return; }
    if (FSpOpenDF(&spec, fsWrPerm, &g_lref) != noErr) { g_lref = 0; }
}

static void log_hex(const char *name, unsigned long v)
{
    char buf[48];
    int  i = 0, d;
    long n;
    if (g_lref == 0) { return; }
    while (name[i] != '\0') { buf[i] = name[i]; i++; }
    buf[i++] = '='; buf[i++] = '0'; buf[i++] = 'x';
    for (d = 28; d >= 0; d -= 4) {
        buf[i++] = "0123456789abcdef"[(v >> d) & 0xF];
    }
    buf[i++] = '\n';
    n = i;
    (void)FSWrite(g_lref, &n, (Ptr)buf);
    (void)FlushVol(NULL, g_lvref);
}

static void log_close(void)
{
    if (g_lref != 0) { (void)FSClose(g_lref); (void)FlushVol(NULL, g_lvref);
                       g_lref = 0; }
}

/* ---- the count hooks (M0) ------------------------------------------------ *
 * Each hook: pass nested calls straight through (guard); else bump the family
 * counter and tail-call the saved standard proc (which does the real drawing
 * and may re-enter other hooks — those see gInCapture set). ticks tracks
 * liveness. Counter writes are aligned u32 = atomic on 68K/PPC, so a reader
 * never tears on a single counter; the seqlock guards the M1 ring.
 */
static void qd_tick(void)
{
    if (gBuf != NULL) { gBuf->ticks = (uint32_t)LMGetTicks(); }
}

/* Retarget/stop can leave an old app's ports hooked until that app next gets
 * a GNE turn and restores them in-context. Such hooks are strict pass-through:
 * only the current active app/A5 and a non-off mode may record. */
static Boolean qd_capture_enabled(void)
{
    return gBuf != NULL && gBuf->cmd.mode != QD_MODE_OFF
        && gTracedA5 != 0
        && (unsigned long)LMGetCurrentA5() == gTracedA5;
}

/* Append one record to the ring (record mode). Never wraps mid-record: if the
 * record would cross the ring end, a WRAP pad fills to the end and the record
 * starts at ring[0]. Header ticks are stamped here. `payload` is copied after
 * the 12-byte header; `size` is padded even. Bounded, allocation-free. */
static void qd_ring_put(uint8_t op, uint8_t flags, unsigned long port,
                        const void *payload, unsigned short payloadLen)
{
    QDShared     *buf = gBuf;
    unsigned long cap;
    unsigned long pos;
    unsigned short recSize;
    QDRecHeader  *h;

    if (buf == NULL) { return; }
    cap = buf->ringCap;
    recSize = (unsigned short)(sizeof(QDRecHeader) + payloadLen);
    recSize = (unsigned short)((recSize + 1) & ~1);   /* even */
    if (recSize > cap) { buf->counters.dropped++; return; }

    buf->seq++;                                        /* seqlock -> odd */

    pos = buf->writeCursor % cap;
    if (pos + recSize > cap) {
        /* pad the tail with a WRAP record (or bare bytes if too small) */
        unsigned long padLen = cap - pos;
        if (padLen >= sizeof(QDRecHeader)) {
            h = (QDRecHeader *)&buf->ring[pos];
            h->size = (unsigned short)padLen;
            h->op = QD_OP_WRAP;
            h->flags = 0;
            h->port = 0;
            h->ticks = (uint32_t)LMGetTicks();
        }
        buf->writeCursor += padLen;
        pos = 0;
    }

    h = (QDRecHeader *)&buf->ring[pos];
    h->size = recSize;
    h->op = op;
    h->flags = flags;
    h->port = (uint32_t)port;
    h->ticks = (uint32_t)LMGetTicks();
    if (payloadLen > 0) {
        BlockMoveData((Ptr)payload, (Ptr)&buf->ring[pos + sizeof(QDRecHeader)],
                      (Size)payloadLen);
    }
    buf->writeCursor += recSize;
    buf->ticks = h->ticks;

    buf->seq++;                                        /* seqlock -> even */
}

/* Emit STATE deltas for `port` before its next op: origin, clip bbox, and
 * fg/bg colour, but only the ones that changed since the last record (the
 * shadow in gInstalled). Keeps the ring lean — a steady redraw emits state
 * once, then just ops. Called at the top of every record function. */
static void qd_emit_state_deltas(GrafPtr port)
{
    short          i, slot = -1;
    QDStatePayload pl;
    Rect           clip;
    Point          origin;
    RGBColor       fg, bg;
    Boolean        first;

    for (i = 0; i < gInstalledCount; i++) {
        if (gInstalled[i].port == port) { slot = i; break; }
    }
    if (slot < 0) { return; }
    first = !gInstalled[slot].stValid;

    origin.h = port->portRect.left;
    origin.v = port->portRect.top;
    if (port->clipRgn != NULL && *port->clipRgn != NULL) {
        clip = (**port->clipRgn).rgnBBox;
    } else {
        clip = port->portRect;
    }
    fg = ((CGrafPtr)port)->rgbFgColor;
    bg = ((CGrafPtr)port)->rgbBkColor;

    pl.pad = 0;
    pl.d = pl.e = pl.f = 0;

    if (first || origin.h != gInstalled[slot].stOrigin.h
        || origin.v != gInstalled[slot].stOrigin.v) {
        pl.kind = QD_STATE_ORIGIN;
        pl.a = origin.h; pl.b = origin.v; pl.c = 0;
        qd_ring_put(QD_OP_STATE, 0, (unsigned long)port, &pl, sizeof(pl));
        gInstalled[slot].stOrigin = origin;
    }
    if (first || clip.left != gInstalled[slot].stClip.left
        || clip.top != gInstalled[slot].stClip.top
        || clip.right != gInstalled[slot].stClip.right
        || clip.bottom != gInstalled[slot].stClip.bottom) {
        pl.kind = QD_STATE_CLIP;
        pl.a = clip.left; pl.b = clip.top; pl.c = clip.right; pl.d = clip.bottom;
        qd_ring_put(QD_OP_STATE, 0, (unsigned long)port, &pl, sizeof(pl));
        pl.d = 0;
        gInstalled[slot].stClip = clip;
    }
    if (first || fg.red != gInstalled[slot].stFg.red
        || fg.green != gInstalled[slot].stFg.green
        || fg.blue != gInstalled[slot].stFg.blue) {
        pl.kind = QD_STATE_FG;
        pl.a = (int16_t)fg.red; pl.b = (int16_t)fg.green; pl.c = (int16_t)fg.blue;
        qd_ring_put(QD_OP_STATE, 0, (unsigned long)port, &pl, sizeof(pl));
        gInstalled[slot].stFg = fg;
    }
    if (first || bg.red != gInstalled[slot].stBg.red
        || bg.green != gInstalled[slot].stBg.green
        || bg.blue != gInstalled[slot].stBg.blue) {
        pl.kind = QD_STATE_BG;
        pl.a = (int16_t)bg.red; pl.b = (int16_t)bg.green; pl.c = (int16_t)bg.blue;
        qd_ring_put(QD_OP_STATE, 0, (unsigned long)port, &pl, sizeof(pl));
        gInstalled[slot].stBg = bg;
    }
    gInstalled[slot].stValid = true;
}

/* Record a drawn text run: the current port's pen + text state + the bytes
 * (truncated to QD_TEXT_MAX inline). Called from the top-level textProc hook. */
static void qd_record_text(short byteCount, const void *textBuf)
{
    QDTextPayload  pl;
    GrafPtr        port = NULL;
    unsigned char  rec[sizeof(QDTextPayload) + QD_TEXT_MAX];
    unsigned short inlineLen;

    GetPort(&port);
    if (port == NULL) { return; }
    qd_emit_state_deltas(port);

    if (byteCount < 0) { byteCount = 0; }
    inlineLen = (byteCount > QD_TEXT_MAX) ? QD_TEXT_MAX : (unsigned short)byteCount;

    pl.penH    = port->pnLoc.h;
    pl.penV    = port->pnLoc.v;
    pl.txFont  = (uint16_t)port->txFont;
    pl.txSize  = (uint16_t)port->txSize;
    pl.txFace  = (uint8_t)port->txFace;
    pl.len     = (uint8_t)inlineLen;
    pl.fullLen = (uint16_t)byteCount;

    BlockMoveData((Ptr)&pl, (Ptr)rec, (Size)sizeof(pl));
    if (inlineLen > 0) {
        BlockMoveData((Ptr)textBuf, (Ptr)(rec + sizeof(pl)), (Size)inlineLen);
    }
    qd_ring_put(QD_OP_TEXT,
                (byteCount > QD_TEXT_MAX) ? QD_FLAG_TRUNC_TEXT : 0,
                (unsigned long)port,
                rec, (unsigned short)(sizeof(pl) + inlineLen));
}

/* Record a line: from the current pen to `newPt`, at the port's pen size. */
static void qd_record_line(Point newPt)
{
    QDLinePayload pl;
    GrafPtr       port = NULL;
    GetPort(&port);
    if (port == NULL) { return; }
    qd_emit_state_deltas(port);
    pl.fromH = port->pnLoc.h;
    pl.fromV = port->pnLoc.v;
    pl.toH   = newPt.h;
    pl.toV   = newPt.v;
    pl.pnH   = port->pnSize.h;
    pl.pnV   = port->pnSize.v;
    qd_ring_put(QD_OP_LINE, 0, (unsigned long)port, &pl, sizeof(pl));
}

/* Record a rect-family op (RECT/RRECT/OVAL/ARC): verb + rect + two extras. */
static void qd_record_rectlike(uint8_t op, GrafVerb verb, const Rect *r,
                               short ext1, short ext2)
{
    QDRectPayload pl;
    GrafPtr       port = NULL;
    GetPort(&port);
    if (port == NULL || r == NULL) { return; }
    qd_emit_state_deltas(port);
    pl.verb = (uint8_t)verb;
    pl.pad  = 0;
    pl.l = r->left;  pl.t = r->top;  pl.r = r->right;  pl.b = r->bottom;
    pl.ext1 = ext1;  pl.ext2 = ext2;
    qd_ring_put(op, 0, (unsigned long)port, &pl, sizeof(pl));
}

/* Record a poly/region op: verb + bounding box (never the point/region data). */
static void qd_record_shape(uint8_t op, GrafVerb verb, const Rect *bbox)
{
    QDRectPayload pl;
    GrafPtr       port = NULL;
    GetPort(&port);
    if (port == NULL || bbox == NULL) { return; }
    qd_emit_state_deltas(port);
    pl.verb = (uint8_t)verb;
    pl.pad  = 0;
    pl.l = bbox->left;  pl.t = bbox->top;
    pl.r = bbox->right; pl.b = bbox->bottom;
    pl.ext1 = 0;  pl.ext2 = 0;
    qd_ring_put(op, 0, (unsigned long)port, &pl, sizeof(pl));
}

/* Record a CopyBits: geometry only, never pixels (M3 composes the pixel island
 * from the dst rect via capture_region). */
static void qd_record_bits(const BitMap *srcBits, const Rect *srcRect,
                           const Rect *dstRect, short mode)
{
    QDBitsPayload pl;
    GrafPtr       port = NULL;
    GetPort(&port);
    if (port == NULL || srcRect == NULL || dstRect == NULL) { return; }
    qd_emit_state_deltas(port);
    pl.sl = srcRect->left;  pl.st = srcRect->top;
    pl.sr = srcRect->right; pl.sb = srcRect->bottom;
    pl.dl = dstRect->left;  pl.dt = dstRect->top;
    pl.dr = dstRect->right; pl.db = dstRect->bottom;
    pl.mode = (uint16_t)mode;
    pl.srcRowBytes = (srcBits != NULL)
        ? (uint16_t)(srcBits->rowBytes & 0x7FFF) : 0;
    qd_ring_put(QD_OP_BITS, 0, (unsigned long)port, &pl, sizeof(pl));
}

static pascal void qd_text(short byteCount, const void *textBuf,
                           Point numer, Point denom)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.text++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) {
                qd_record_text(byteCount, textBuf);
            } else {
                qd_tick();
            }
        }
        InvokeQDTextUPP(byteCount, textBuf, numer, denom, gStd.textProc);
        gInCapture = 0;
    } else {
        InvokeQDTextUPP(byteCount, textBuf, numer, denom, gStd.textProc);
    }
}

static pascal void qd_line(Point newPt)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.line++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { qd_record_line(newPt); }
            else { qd_tick(); }
        }
        InvokeQDLineUPP(newPt, gStd.lineProc);
        gInCapture = 0;
    } else {
        InvokeQDLineUPP(newPt, gStd.lineProc);
    }
}

static pascal void qd_rect(GrafVerb verb, const Rect *r)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.rect++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { qd_record_rectlike(QD_OP_RECT, verb, r, 0, 0); }
            else { qd_tick(); }
        }
        InvokeQDRectUPP(verb, r, gStd.rectProc);
        gInCapture = 0;
    } else {
        InvokeQDRectUPP(verb, r, gStd.rectProc);
    }
}

static pascal void qd_rrect(GrafVerb verb, const Rect *r,
                            short ovalWidth, short ovalHeight)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.rrect++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { qd_record_rectlike(QD_OP_RRECT, verb, r, ovalWidth, ovalHeight); }
            else { qd_tick(); }
        }
        InvokeQDRRectUPP(verb, r, ovalWidth, ovalHeight, gStd.rRectProc);
        gInCapture = 0;
    } else {
        InvokeQDRRectUPP(verb, r, ovalWidth, ovalHeight, gStd.rRectProc);
    }
}

static pascal void qd_oval(GrafVerb verb, const Rect *r)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.oval++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { qd_record_rectlike(QD_OP_OVAL, verb, r, 0, 0); }
            else { qd_tick(); }
        }
        InvokeQDOvalUPP(verb, r, gStd.ovalProc);
        gInCapture = 0;
    } else {
        InvokeQDOvalUPP(verb, r, gStd.ovalProc);
    }
}

static pascal void qd_arc(GrafVerb verb, const Rect *r,
                          short startAngle, short arcAngle)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.arc++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { qd_record_rectlike(QD_OP_ARC, verb, r, startAngle, arcAngle); }
            else { qd_tick(); }
        }
        InvokeQDArcUPP(verb, r, startAngle, arcAngle, gStd.arcProc);
        gInCapture = 0;
    } else {
        InvokeQDArcUPP(verb, r, startAngle, arcAngle, gStd.arcProc);
    }
}

static pascal void qd_poly(GrafVerb verb, PolyHandle poly)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.poly++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { if (poly) { qd_record_shape(QD_OP_POLY, verb, &((*poly)->polyBBox)); } }
            else { qd_tick(); }
        }
        InvokeQDPolyUPP(verb, poly, gStd.polyProc);
        gInCapture = 0;
    } else {
        InvokeQDPolyUPP(verb, poly, gStd.polyProc);
    }
}

static pascal void qd_rgn(GrafVerb verb, RgnHandle rgn)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.rgn++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { if (rgn) { qd_record_shape(QD_OP_RGN, verb, &((*rgn)->rgnBBox)); } }
            else { qd_tick(); }
        }
        InvokeQDRgnUPP(verb, rgn, gStd.rgnProc);
        gInCapture = 0;
    } else {
        InvokeQDRgnUPP(verb, rgn, gStd.rgnProc);
    }
}

static pascal void qd_bits(const BitMap *srcBits, const Rect *srcRect,
                           const Rect *dstRect, short mode, RgnHandle maskRgn)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) {
            gBuf->counters.bits++;
            if (gBuf->cmd.mode == QD_MODE_RECORD) { qd_record_bits(srcBits, srcRect, dstRect, mode); }
            else { qd_tick(); }
        }
        InvokeQDBitsUPP(srcBits, srcRect, dstRect, mode, maskRgn,
                        gStd.bitsProc);
        gInCapture = 0;
    } else {
        InvokeQDBitsUPP(srcBits, srcRect, dstRect, mode, maskRgn,
                        gStd.bitsProc);
    }
}

static pascal void qd_comment(short kind, short dataSize, Handle dataHandle)
{
    if (!gInCapture && qd_capture_enabled()) {
        gInCapture = 1;
        if (gBuf) { gBuf->counters.comment++; qd_tick(); }
        InvokeQDCommentUPP(kind, dataSize, dataHandle, gStd.commentProc);
        gInCapture = 0;
    } else {
        InvokeQDCommentUPP(kind, dataSize, dataHandle, gStd.commentProc);
    }
}

/* ---- install / uninstall / repair (traced app's context only) ------------ */

static Boolean qd_in_table(GrafPtr port)
{
    short i;
    for (i = 0; i < gInstalledCount; i++) {
        if (gInstalled[i].port == port) { return true; }
    }
    return false;
}

static Boolean qd_same_psn(const ProcessSerialNumber *a,
                           const ProcessSerialNumber *b)
{
    return a->highLongOfPSN == b->highLongOfPSN
        && a->lowLongOfPSN == b->lowLongOfPSN;
}

static Boolean qd_has_active_process(void)
{
    return gActivePSN.lowLongOfPSN != kNoProcess;
}

/* Process Manager enumeration is used only when a command needs table space.
 * It distinguishes a live retired owner (leave its pointers untouched until
 * its own GNE turn) from an exited owner (forget without dereferencing). */
static Boolean qd_process_exists(const ProcessSerialNumber *wanted)
{
    ProcessSerialNumber psn = { 0, kNoProcess };
    short guard = 0;

    while (guard < 256 && GetNextProcess(&psn) == noErr) {
        if (qd_same_psn(&psn, wanted)) { return true; }
        guard++;
    }
    return false;
}

static Boolean qd_port_is_live(GrafPtr port, WindowPeek head)
{
    WindowPeek w = head;
    short guard = 0;

    while (w != NULL && guard < 128) {
        if ((GrafPtr)w == port) { return true; }
        w = w->nextWindow;
        guard++;
    }
    return false;
}

/* GrafPort and CGrafPort are the same size but have different layouts. The
 * Color QuickDraw discriminator occupies this word only in a CGrafPort; a
 * classic GrafPort reads as a non-0xC000 value here. Never touch grafProcs at
 * the CGrafPort offset until this check passes. */
static Boolean qd_port_is_color(GrafPtr port)
{
    return port != NULL
        && (((unsigned short)((CGrafPtr)port)->portVersion & 0xC000U)
            == 0xC000U);
}

static void qd_clear_active(void)
{
    gActivePSN.highLongOfPSN = 0;
    gActivePSN.lowLongOfPSN = kNoProcess;
    gTracedA5 = 0;
    gLastA5 = 0;
    gLastWindowList = 0;
    gLastTicks = 0;
}

/* Dead application heaps are already unmapped/reclaimed. Remove their table
 * rows by value only; never test grafProcs through a dead port pointer. */
static void qd_prune_dead_owners(void)
{
    short i = 0;

    while (i < gInstalledCount) {
        if (!qd_process_exists(&gInstalled[i].owner)) {
            gInstalled[i] = gInstalled[gInstalledCount - 1];
            gInstalledCount--;
        } else {
            i++;
        }
    }
}

/* Install our hooks on one window port. Only ports with no existing grafProcs
 * are hooked (an app with its own custom procs is left alone and counted as
 * skipped — chaining to unknown procs is a v1 non-goal). */
static void qd_install_port(GrafPtr port)
{
    CQDProcsPtr prev;
    if (port == NULL || qd_in_table(port) || gInstalledCount >= QD_TABLE_MAX) {
        if (gInstalledCount >= QD_TABLE_MAX && gBuf) {
            gBuf->counters.skippedPorts++;
        }
        return;
    }
    if (!qd_port_is_color(port)) {
        if (gBuf) { gBuf->counters.skippedPorts++; }
        return;
    }
    prev = ((CGrafPtr)port)->grafProcs;
    if (prev != NULL) {                      /* app already customises: skip  */
        if (gBuf) { gBuf->counters.skippedPorts++; }
        return;
    }
    gInstalled[gInstalledCount].port = port;
    gInstalled[gInstalledCount].prev = prev;
    gInstalled[gInstalledCount].owner = gActivePSN;
    gInstalled[gInstalledCount].stValid = false;   /* force STATE deltas */
    gInstalledCount++;
    ((CGrafPtr)port)->grafProcs = &gHooks;
    if (gBuf) { gBuf->counters.installs++; }
}

/* Remove our hooks from every port we installed (restore the saved grafProcs).
 * A port whose window was disposed is simply forgotten — nothing dispatches
 * through a freed port, and our resident code never dangles. */
static void qd_uninstall_owned(const ProcessSerialNumber *owner)
{
    WindowPeek head = (WindowPeek)LMGetWindowList();
    short i = 0;

    while (i < gInstalledCount) {
        GrafPtr port = gInstalled[i].port;
        if (!qd_same_psn(&gInstalled[i].owner, owner)) {
            i++;
            continue;
        }
        /* A disposed WindowRecord belongs to free application-heap memory.
         * Prove membership in the CURRENT app's WindowList before the first
         * dereference; a stale entry is forgotten, never restored cross-heap. */
        if (qd_port_is_live(port, head)
            && qd_port_is_color(port)
            && ((CGrafPtr)port)->grafProcs == &gHooks) {
            ((CGrafPtr)port)->grafProcs = gInstalled[i].prev;
            if (gBuf) { gBuf->counters.uninstalls++; }
        }
        gInstalled[i] = gInstalled[gInstalledCount - 1];
        gInstalledCount--;
    }
}

/* Walk the current app's WindowList and install on any window we haven't yet
 * hooked. Called at command-apply and on the repair sweep. */
static void qd_install_windowlist(void)
{
    WindowPeek w = (WindowPeek)LMGetWindowList();
    short guard = 0;
    while (w != NULL && guard < 128) {
        qd_install_port((GrafPtr)w);
        w = w->nextWindow;
        guard++;
    }
}

/* Repair: (1) prune table entries whose port is no longer in the WindowList
 * (window closed); (2) install on any new windows. Keeps coverage current as
 * the app opens/closes windows, without a fresh command. */
static void qd_repair(void)
{
    WindowPeek head = (WindowPeek)LMGetWindowList();
    short i;
    /* prune */
    for (i = 0; i < gInstalledCount; ) {
        if (qd_same_psn(&gInstalled[i].owner, &gActivePSN)
            && !qd_port_is_live(gInstalled[i].port, head)) {
                                                /* window gone: forget only  */
            gInstalled[i] = gInstalled[gInstalledCount - 1];
            gInstalledCount--;
        } else {
            i++;
        }
    }
    qd_install_windowlist();
    if (gBuf) { gBuf->counters.repairs++; }
}

/* ---- GNE-context command applier (called by qdgne.S every event loop) ----- *
 * Runs in each app's own context at event-loop time (Toolbox-safe). Applies a
 * pending command when we're in the traced app; then, cheaply gated on the
 * traced A5, runs the repair sweep. */
void qd_gne_apply(void)
{
    QDShared *buf = gBuf;
    ProcessSerialNumber current;
    ProcessSerialNumber requested;
    Boolean haveCurrent;
    unsigned long a5;
    unsigned long ticks;
    unsigned long windowList;
    if (buf == NULL) { return; }
    a5 = (unsigned long)LMGetCurrentA5();
    haveCurrent = (GetCurrentProcess(&current) == noErr);

    if (buf->cmd.cmdSeq != buf->cmd.ackSeq) {
        if (buf->cmd.mode == QD_MODE_OFF) {
            /* Capture becomes off immediately. Physical restoration is done
             * below if this is the owner's context, or at its next GNE turn. */
            qd_clear_active();
            buf->counters.cmdApplies++;
            buf->cmd.ackSeq = buf->cmd.cmdSeq;
        } else {
            requested.highLongOfPSN = buf->cmd.psnHi;
            requested.lowLongOfPSN = buf->cmd.psnLo;
            if (!qd_has_active_process()
                || !qd_same_psn(&requested, &gActivePSN)) {
                /* Old hooks remain resident pass-through until their owner
                 * runs. Clearing A5 disables them before another app runs. */
                qd_clear_active();
                gActivePSN = requested;
            }
            qd_prune_dead_owners();
            if (haveCurrent && qd_same_psn(&current, &gActivePSN)) {
                qd_install_windowlist();
                gTracedA5 = a5;
                gLastA5 = a5;
                gLastWindowList = (unsigned long)LMGetWindowList();
                gLastTicks = (unsigned long)LMGetTicks();
                buf->counters.cmdApplies++;
                buf->cmd.ackSeq = buf->cmd.cmdSeq;
            }
        }
        /* A start waits only for the NEW target's GNE turn. Old owners never
         * block it; their hooks are already pass-through and self-restore. */
    }

    if (haveCurrent && (!qd_has_active_process()
        || !qd_same_psn(&current, &gActivePSN))) {
        qd_uninstall_owned(&current);
    }

    if (buf->cmd.mode != QD_MODE_OFF && qd_has_active_process()
        && haveCurrent && qd_same_psn(&current, &gActivePSN)
        && a5 == gTracedA5 && gTracedA5 != 0) {
        /* A WindowList head change catches opens/head closes immediately. The
         * half-second sweep catches non-head closes without charging every GNE
         * on a 33 MHz machine. Unsigned subtraction is TickCount-wrap safe. */
        ticks = (unsigned long)LMGetTicks();
        windowList = (unsigned long)LMGetWindowList();
        if (windowList != gLastWindowList || ticks - gLastTicks >= 30UL) {
            qd_repair();
            gLastWindowList = (unsigned long)LMGetWindowList();
            gLastTicks = ticks;
        }
        gLastA5 = a5;
    }
}

/* ---- Gestalt publisher --------------------------------------------------- */
static pascal OSErr qd_gestalt(OSType selector, long *response)
{
#pragma unused(selector)
    *response = (long)gBuf;
    return noErr;
}

/* ---- install ------------------------------------------------------------- */
void _start(void)
{
    Handle              self;
    SelectorFunctionUPP gestaltUPP;
    OSErr               err;

    RETRO68_RELOCATE();
    Retro68CallConstructors();

    log_open();
    log_hex("qdpeek", QD_VERSION);

    self = Get1Resource('INIT', 128);
    log_hex("selfrsrc", (unsigned long)self);
    if (self == NULL) { log_close(); return; }
    DetachResource(self);

    gBuf = (QDShared *)NewPtrSysClear((Size)sizeof(QDShared));
    if (gBuf == NULL) { log_hex("buf", 0); log_close(); return; }
    gBuf->version = QD_VERSION;
    gBuf->ringCap = QD_RING_CAP;

    /* Build the hook table: fill with the standard color bottlenecks, save a
     * copy to call through, then override the ten families we track. All
     * ports share this one record; the current port at draw time tags the op
     * (M1). UPPs are RoutineDescriptors so native Color QD calls our 68K code
     * through Mixed Mode. */
    SetStdCProcs(&gStd);
    gHooks = gStd;
    gHooks.textProc    = NewQDTextUPP(qd_text);
    gHooks.lineProc    = NewQDLineUPP(qd_line);
    gHooks.rectProc    = NewQDRectUPP(qd_rect);
    gHooks.rRectProc   = NewQDRRectUPP(qd_rrect);
    gHooks.ovalProc    = NewQDOvalUPP(qd_oval);
    gHooks.arcProc     = NewQDArcUPP(qd_arc);
    gHooks.polyProc    = NewQDPolyUPP(qd_poly);
    gHooks.rgnProc     = NewQDRgnUPP(qd_rgn);
    gHooks.bitsProc    = NewQDBitsUPP(qd_bits);
    gHooks.commentProc = NewQDCommentUPP(qd_comment);

    gBuf->magic = QD_MAGIC;                   /* magic last: liveness flag     */
    log_hex("buf", (unsigned long)gBuf);

    gestaltUPP = NewSelectorFunctionUPP(qd_gestalt);
    err = NewGestalt(QD_GESTALT, gestaltUPP);
    if (err != noErr) {
        log_hex("gesterr", (unsigned long)(unsigned short)err);
        DisposeSelectorFunctionUPP(gestaltUPP);
        DisposePtr((Ptr)gBuf);
        gBuf = NULL;
        log_close();
        return;
    }

    gOldGNEFilter = LMGetGNEFilter();
    LMSetGNEFilter((GetNextEventFilterUPP)qd_gne_filter);
    log_hex("oldgne", (unsigned long)gOldGNEFilter);
    log_hex("newgne", (unsigned long)qd_gne_filter);
    log_close();
    /* Resident forever: no Retro68FreeGlobals(). */
}
