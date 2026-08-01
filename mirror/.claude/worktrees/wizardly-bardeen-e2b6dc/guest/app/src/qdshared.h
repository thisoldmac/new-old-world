/*
 * qdshared.h - the QDPeek shared-buffer contract (QDPEEK-SPEC.md).
 *
 * Shared between the QDPeek INIT (writer, in each app's draw + event context)
 * and the toolkit-worker `qdtrace` verb (reader, normal context). One
 * NewPtrSys block in the system heap, globally addressable; its address is
 * published via Gestalt('TBqd').
 *
 * M0 populates the counters and the command block only; the ring is declared
 * at its final v1 layout so M1 adds records without churning this header. Keep
 * this header free of Toolbox types so the host-side worker can include it
 * verbatim.
 *
 * Coherence: a seqlock over counters+cursor+ring (AXShared discipline) — the
 * writer bumps `seq` odd before touching them and even after; the reader
 * samples, copies, re-samples, retries while odd or changed. Classic Mac OS is
 * cooperative, so there is one drawer at a time; the seqlock only guards the
 * rare reader/writer overlap.
 */
#ifndef QDPEEK_QDSHARED_H
#define QDPEEK_QDSHARED_H

#include <stddef.h>
#include <stdint.h>

/* 'TBqd' - buffer magic and the Gestalt selector that publishes its address. */
#define QD_MAGIC    0x54427164UL
#define QD_GESTALT  0x54427164UL
#define QD_VERSION  1UL

#define QD_RING_CAP 65536UL       /* v1 ring size; reported in status         */
#define QD_TEXT_MAX 64            /* inline text bytes per TEXT record        */
#define QD_TABLE_MAX 16           /* max simultaneously-hooked window ports   */

/* mode: how the resident hooks behave. */
#define QD_MODE_OFF    0UL        /* hooks uninstalled                        */
#define QD_MODE_COUNT  1UL        /* hooks installed, bump counters only (M0) */
#define QD_MODE_RECORD 2UL        /* count + append ring records (M1)         */

/*
 * Command block: the worker writes the request and bumps `cmdSeq`; the INIT
 * applies it at the traced app's next event-loop (GNE) moment and sets
 * `ackSeq = cmdSeq`. A worker polls `status.applied` (ackSeq == cmdSeq).
 */
typedef struct {
    volatile uint32_t cmdSeq;     /* bumped after the fields below are set    */
    volatile uint32_t ackSeq;     /* INIT sets == cmdSeq once applied         */
    uint32_t          mode;       /* QD_MODE_*                                */
    uint32_t          psnHi;      /* traced process serial number             */
    uint32_t          psnLo;
} QDCommand;

/* Committed operations by bottleneck family, plus honesty counters. */
typedef struct {
    uint32_t text, line, rect, rrect, oval, arc, poly, rgn, bits, comment;
    uint32_t other;              /* a hooked proc with no dedicated counter   */
    uint32_t dropped;            /* ring-full / busy-flag collisions (M1)     */
    uint32_t skippedPorts;       /* non-color or already-custom grafProcs     */
    uint32_t installs, uninstalls, repairs, cmdApplies;
} QDCounters;

typedef struct {
    uint32_t          magic;      /* QD_MAGIC once the INIT is live            */
    uint32_t          version;    /* QD_VERSION                               */
    volatile uint32_t seq;        /* seqlock; odd = write in progress         */
    uint32_t          ticks;      /* TickCount at last commit (liveness)      */
    QDCommand         cmd;
    QDCounters        counters;
    uint32_t          ringCap;    /* == QD_RING_CAP                           */
    uint32_t          writeCursor;/* monotonic byte count; pos = cursor % cap */
    uint8_t           ring[QD_RING_CAP];
} QDShared;

/*
 * Ring records (M1). 2-byte aligned, never wrapped mid-record: when a record
 * would cross the ring end, a WRAP record pads to the end and the real record
 * starts at ring[0]. The reader consumes [readerCursor, writeCursor); on a
 * uniprocessor cooperative guest the traced app isn't running during a fetch,
 * so records below writeCursor are always complete. Overrun (writeCursor -
 * readerCursor > ringCap) means the reader lost data -> resync.
 */
#define QD_OP_TEXT     1
#define QD_OP_LINE     2
#define QD_OP_RECT     3
#define QD_OP_RRECT    4
#define QD_OP_OVAL     5
#define QD_OP_ARC      6
#define QD_OP_POLY     7
#define QD_OP_RGN      8
#define QD_OP_BITS     9
#define QD_OP_COMMENT  10
#define QD_OP_STATE    11
#define QD_OP_WRAP     255

#define QD_FLAG_TRUNC_TEXT 0x01   /* text run longer than QD_TEXT_MAX inline  */

/* STATE delta kinds (M2b): emitted before an op when the port's drawing state
 * differs from the last-recorded shadow, so the host places and colours ops
 * correctly. clip/origin use signed coords; fg/bg carry RGBColor components
 * (unsigned 0-65535, stored in the same 16-bit fields). */
#define QD_STATE_CLIP    1        /* a,b,c,d = clip bbox l,t,r,b               */
#define QD_STATE_ORIGIN  2        /* a,b = port origin h,v (portRect topLeft)  */
#define QD_STATE_FG      3        /* a,b,c = rgbFgColor r,g,b                   */
#define QD_STATE_BG      4        /* a,b,c = rgbBgColor r,g,b                   */

typedef struct {
    uint16_t size;               /* whole record incl. header + pad (even)    */
    uint8_t  op;                 /* QD_OP_*                                    */
    uint8_t  flags;              /* QD_FLAG_*                                  */
    uint32_t port;               /* CGrafPtr — the window identity key        */
    uint32_t ticks;              /* TickCount at capture                      */
} QDRecHeader;                   /* 12 bytes                                  */

/* TEXT payload (follows the header): the jackpot — a drawn text run with the
 * port's text state, so the host replays it through the matching NFNT strike. */
typedef struct {
    int16_t  penH, penV;         /* pen location at draw time                 */
    uint16_t txFont;             /* port txFont / txSize                      */
    uint16_t txSize;
    uint8_t  txFace;             /* style bits                                */
    uint8_t  len;                /* inline bytes that follow (<= QD_TEXT_MAX) */
    uint16_t fullLen;            /* the run's true length (>= len if trunc)   */
    /* uint8_t bytes[len]; then pad to even */
} QDTextPayload;

/* LINE payload: the pen moves from `from` to `to` (the hook reads pnLoc as the
 * start, its arg as the end) with pen size `pn`. */
typedef struct {
    int16_t fromH, fromV, toH, toV, pnH, pnV;
} QDLinePayload;                 /* 12 bytes                                  */

/* RECT/RRECT/OVAL/ARC payload: a GrafVerb (frame/paint/erase/invert/fill) + a
 * rect + two extra shorts. ext1/ext2 = ovalWidth/ovalHeight (RRECT),
 * startAngle/arcAngle (ARC), or 0 (RECT/OVAL). POLY/RGN reuse it: l..b hold the
 * bounding box, verb the op, ext = 0. */
typedef struct {
    uint8_t  verb;
    uint8_t  pad;
    int16_t  l, t, r, b;
    int16_t  ext1, ext2;
} QDRectPayload;                 /* 14 bytes                                  */

/* BITS payload: geometry only, never pixels (M3 composes the pixel island via
 * capture_region using the dst rect). */
typedef struct {
    int16_t  sl, st, sr, sb;     /* src rect                                  */
    int16_t  dl, dt, dr, db;     /* dst rect                                  */
    uint16_t mode;               /* transfer mode                             */
    uint16_t srcRowBytes;        /* source rowBytes (& 0x7FFF)                */
} QDBitsPayload;                 /* 20 bytes                                  */

/* STATE payload: a kind + up to six 16-bit fields (see QD_STATE_* for use). */
typedef struct {
    uint8_t  kind;
    uint8_t  pad;
    int16_t  a, b, c, d, e, f;
} QDStatePayload;                /* 14 bytes                                  */

_Static_assert(sizeof(QDRecHeader) == 12, "QDRecHeader layout changed");
_Static_assert(sizeof(QDTextPayload) == 12, "QDTextPayload layout changed");
_Static_assert(sizeof(QDLinePayload) == 12, "QDLinePayload layout changed");
_Static_assert(sizeof(QDRectPayload) == 14, "QDRectPayload layout changed");
_Static_assert(sizeof(QDBitsPayload) == 20, "QDBitsPayload layout changed");
_Static_assert(sizeof(QDStatePayload) == 14, "QDStatePayload layout changed");

_Static_assert(sizeof(QDCommand) == 20, "QDCommand wire layout changed");
_Static_assert(sizeof(QDCounters) == 68, "QDCounters wire layout changed");
_Static_assert(offsetof(QDShared, cmd) == 16, "QDShared header layout changed");
_Static_assert(offsetof(QDShared, counters) == 36,
               "QDShared counters offset changed");
_Static_assert(offsetof(QDShared, ring) == 112,
               "QDShared ring offset changed");

#endif /* QDPEEK_QDSHARED_H */
