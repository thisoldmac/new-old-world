/*
 * vprobe68.c - implementation of vprobe68.h. Read that header first: it
 * carries what the rows MEAN, including the four readings of the
 * MOVEM.L / reread pair this run is shaped around.
 *
 * STATIC BUDGET (file-scope BSS, no allocation on any path except the one
 * band GWorld below, which is disposed before this function returns):
 *   g_sink / g_sinkd                     12 bytes
 *   g_running (re-entry guard)            2 bytes
 *   ----------------------------------------------
 *   total                                14 bytes
 * The band GWorld is the only heap block: 640 x 32 x 8 bits = 20 KB,
 * taken and given back inside one call. A whole-frame offscreen copy
 * would be 300 KB against a 384 KB partition - not affordable, and not
 * needed, because CopyBits can be timed a band at a time and the fidelity
 * check reuses the same band. The row table itself is the caller's
 * (commands68.c holds one in BSS); this file owns none.
 *
 * No printf family (numfmt.h and n68_vprobe.h's formatters only), matching
 * the rest of guest68k/src.
 *
 * THE ONE FILE IN THIS TREE WITH INLINE ASSEMBLY, and only because the two
 * idioms it measures have no C spelling: a compiler will not emit MOVEM.L
 * for a read whose values are discarded, and there is no portable way to
 * ask for a 64-bit FPU load. Both are gated - see read_fp64's comment for
 * the runtime FPU check, and guest68k/CMakeLists.txt for why this file
 * alone is assembled with -mcpu=68030 while its generated code stays
 * 68000.
 */
#include "vprobe68.h"

#include "log.h"
#include "numfmt.h"
#include "wire68.h"

#include <Events.h>
#include <Gestalt.h>
#include <QDOffscreen.h>
#include <Quickdraw.h>
#include <Timer.h>

#include <string.h>

enum {
    /* How long one timed pass may take before it is shortened to fit.
     * Nothing inside a read loop pumps the wire, so this is also the
     * longest stretch of deafness the probe can cause; the host gives up
     * after ~65 s (wire68.c's kWireDeadTicks).
     *
     * WORST CASE FOR THE WHOLE RUN, since a bound nobody adds up is not a
     * bound: six raw methods at one budgeted pass each (7.2 s), the
     * 32-bit method's second pass for the reread row (+1.2), a calibration
     * slice per method at 1/30th of a frame (+0.3 total), five partial
     * passes at a tenth of a frame (+0.6), the CopyBits baseline (+1.2)
     * and the fidelity sweep (+1.2, memcmp included) = ~11.7 s, with the
     * wire pumped between every one of them. Even at three times the
     * predicted per-pass cost the run stays far inside the death window,
     * which is the property that matters: the numbers may surprise, the
     * duration may not. */
    kPhaseBudgetUs = 1200000L,

    /* The calibration slice: enough rows that a slow machine's timer can
     * resolve it, few enough that it costs ~3% of a frame. Its only job is
     * to predict the full pass so the pass can be shortened. */
    kSliceRows = 16,

    /* Every read loop steps 32 bytes (MOVEM.L of eight registers), so
     * every extent is a multiple of 32 - a remainder would be read by some
     * other code path and pollute the row it belongs to. */
    kReadAlign = 32,

    /* One CopyBits band. 640 x 32 at 8 bits is 20 KB of offscreen, small
     * enough to take from a 384 KB partition and large enough that the
     * per-call overhead (port swap, locks, clipping) is not what is being
     * measured. */
    kBandRows = 32,

    /* Samples for the timer-resolution row. Enough to see the step of a
     * clock that ticks in tens of microseconds, cheap enough to be free. */
    kTimerSamples = 2000,

    /* Partial-read linearity: the same tenth-of-a-screen the PowerPC guest
     * uses, timed five times and best-of, so the row can be compared
     * against docs/vram-readout.md's "60 rows cost 10.3 ms measured vs
     * 10.4 predicted" directly. */
    kPartialDivisor = 10,
    kPartialTries = 5
};

/* Every method funnels its reads into these sinks so the compiler cannot
 * elide a loop, and every method pays the same store cost - the numbers
 * compare methods, not sink strategies. Verbatim in intent from the
 * PowerPC guest's vprobe.c, including the rule about the double sink: it
 * is written by plain assignment only, so no FP arithmetic ever touches
 * framebuffer bits. */
static volatile unsigned long g_sink;
static volatile double        g_sinkd;

/* Re-entry guard. vprobe68_run pumps the wire between phases, and a
 * command.request arriving during one of those pumps can reach this
 * module again on the same stack. proc68.c carries the same guard for the
 * same hazard; here the consequence would be worse than deep recursion -
 * the inner probe's numbers would be the outer probe's stalls. */
static Boolean g_running = false;

/* ---- clock ---------------------------------------------------------------- */

/* Microseconds() is a trap (Timer.h: FOURWORDINLINE(0xA193, ...),
 * InterfaceLib 7.1 and later), so it costs nothing to call and needs no
 * library. Only the low half is used: it wraps every ~71 minutes and no
 * pass here is longer than a couple of seconds. TickCount would not do -
 * at 60 Hz its step is 16667 us, which is a large fraction of most of the
 * passes below and larger than all of the partial ones.
 *
 * ASSUMED PRESENT, NOT PROVEN PRESENT. The trap is documented from System
 * 7.0 onwards and this application targets 7.1 on one machine, so it is
 * taken on the documentation. It is deliberately NOT gated by a
 * NGetTrapAddress check: getting an OS-trap availability test subtly
 * wrong fails CLOSED in the wrong direction - it would disable vprobe on a
 * machine where the trap works perfectly - and the check itself cannot be
 * verified from here either. If the 180c turns out not to implement it,
 * the symptom is an unimplemented-trap crash at the Timer row and the fix
 * is a gate written against a machine someone can watch. First thing to
 * confirm on metal.
 *
 * Its RESOLUTION is a different question and is measured rather than
 * assumed - see timer_step_us and the Timer row. */
static unsigned long now_us(void)
{
    UnsignedWide t;

    Microseconds(&t);
    return t.lo;
}

/* The clock's actual resolution, measured rather than assumed. A timing
 * source nobody characterised makes every row below it suspect: if
 * Microseconds steps in units of 20 us on this machine, a 300 us pass is
 * known to 7%, and the partial-read row - the shortest thing timed here -
 * is the one that would silently become noise. Returns the smallest
 * non-zero step seen and, through `dups`, how many of the samples saw no
 * change at all. */
static unsigned long timer_step_us(long samples, long *dups)
{
    unsigned long best = 0xFFFFFFFFUL;
    unsigned long prev = now_us();
    long same = 0;
    long i;

    for (i = 0; i < samples; ++i) {
        unsigned long now = now_us();

        if (now == prev) {
            ++same;
        } else {
            unsigned long delta = now - prev;

            if (delta < best) {
                best = delta;
            }
            prev = now;
        }
    }
    if (dups != NULL) {
        *dups = same;
    }
    return best == 0xFFFFFFFFUL ? 0UL : best;
}

/* ---- pumping -------------------------------------------------------------- */

/* Between phases, never inside one. Mirrors proc68.c's yield_ticks(0): an
 * event mask of 0 so nothing is dequeued on another application's behalf,
 * and the wire pumped so a probe does not stall the connection for its
 * whole run. The guard is proc68.c's, for the same reason - wire_idle()
 * can walk all the way back into command dispatch. */
static void vprobe_pump(void)
{
    static Boolean pumping = false;
    EventRecord event;

    if (!pumping) {
        pumping = true;
        wire_idle();
        pumping = false;
    }
    (void)WaitNextEvent(0, &event, 0, NULL);
}

/* ---- the read methods ----------------------------------------------------- */

typedef void (*ReadFn)(const char *base, long bytes);

static void read8(const char *base, long bytes)
{
    const volatile unsigned char *p = (const volatile unsigned char *)base;
    unsigned long acc = 0;
    long i;

    for (i = 0; i < bytes; ++i) {
        acc ^= p[i];
    }
    g_sink = acc;
}

static void read16(const char *base, long bytes)
{
    const volatile unsigned short *p = (const volatile unsigned short *)base;
    long n = bytes / 2;
    unsigned long acc = 0;
    long i;

    for (i = 0; i < n; ++i) {
        acc ^= p[i];
    }
    g_sink = acc;
}

static void read32(const char *base, long bytes)
{
    const volatile unsigned long *p = (const volatile unsigned long *)base;
    long n = bytes / 4;
    unsigned long acc = 0;
    long i;

    for (i = 0; i < n; ++i) {
        acc ^= p[i];
    }
    g_sink = acc;
}

/* Eight long reads per loop iteration. On the PB1400c this was identical
 * to the rolled version to the microsecond - the wall was the bus, never
 * the loop. If the two differ here, the 68030's loop overhead is a real
 * fraction of the read and the capture stage should be unrolled. */
static void read32u8(const char *base, long bytes)
{
    const volatile unsigned long *p = (const volatile unsigned long *)base;
    long n = (bytes / 4) & ~7L;
    unsigned long acc = 0;
    long i;

    for (i = 0; i < n; i += 8) {
        acc ^= p[i];
        acc ^= p[i + 1];
        acc ^= p[i + 2];
        acc ^= p[i + 3];
        acc ^= p[i + 4];
        acc ^= p[i + 5];
        acc ^= p[i + 6];
        acc ^= p[i + 7];
    }
    g_sink = acc;
}

/* MOVEM.L, the 68K bulk-read idiom: eight registers, 32 bytes, one
 * instruction. THE row this probe was written for - see vprobe68.h for
 * what it means read together with the reread row.
 *
 * ALL EIGHT DATA REGISTERS, AND NO ADDRESS REGISTER IN THE LIST. An
 * earlier version loaded d0-d5/a0-a1 to leave gcc a data register for the
 * loop counter, and gcc duly allocated the pointer itself to a0 - which
 * put the base register inside its own load list. What that does is
 * processor-dependent (the 68020 and later write back the incremented
 * address; the 68000 writes the value read from memory), so the loop
 * would have run on framebuffer bits as its own pointer on some machines.
 * It did not show up in testing because the machine it was written for is
 * the one where it happens to work.
 *
 * The loop is bounded by an END POINTER rather than a counter so no data
 * register is needed at all: `p < end` is a cmpa.l between two address
 * registers. That keeps every data register available to the MOVEM and
 * keeps the counter off the stack - a spilled counter would add a
 * cached-RAM access to every 32 bytes of an uncached-VRAM measurement.
 * The post-increment form is the idiom itself: no separate lea.
 *
 * The loaded values never reach C, so there is nothing to XOR into the
 * sink per element; the sink is written once per pass, which differs from
 * the other methods by one store per PASS rather than per element. */
static void read_movem(const char *base, long bytes)
{
    const char *p = base;
    const char *end = base + (bytes & ~31L);

    while (p < end) {
        __asm__ __volatile__ (
            "movem.l (%0)+,%%d0-%%d7"
            : "+a" (p)
            :
            : "d0", "d1", "d2", "d3", "d4", "d5", "d6", "d7", "memory");
    }
    g_sink = (unsigned long)(p - base);
}

/* fmove.d through the 68882 - the analogue of the PowerPC guest's `lfd`,
 * and the widest single load this machine has. On the 1400c the 64-bit
 * load was the fastest method and the floor for whole-frame capture.
 *
 * TWO CAVEATS, both stated because they are the difference between a
 * number and a misleading one:
 *
 * 1. GATED AT RUNTIME. This is a 68000-targeted build; the instruction
 *    exists only because CMakeLists assembles this file for a 68030, and
 *    it is reached only after Gestalt says an FPU is present. A 68LC040
 *    or a 68030 without its 68882 would take an F-line trap here, which
 *    on System 7.1 with no FPU emulation is a crash, not a slow path.
 * 2. DATA-DEPENDENT, unlike every other row here. fmove.d CONVERTS its
 *    operand to extended precision, and a 68882 handles a denormalised
 *    input far more slowly than a normalised one. The operand is
 *    framebuffer bits, so this row's cost depends on what is on screen -
 *    a dark region with detail (small exponents) can be slower than a
 *    flat one. No exception is ever taken: FPCR's enables are untouched
 *    and left at zero, so a NaN or a denormal only sets a status bit.
 *    Read this row as "what an FPU-based reader would cost on THIS
 *    screen", not as a bus figure. fmovem.x would avoid the conversion
 *    entirely (it moves extended-format bits with no interpretation) and
 *    is the honest next measurement if this row comes back strange - it
 *    is left out only because the reply cannot carry a seventeenth row.
 */
static void read_fp64(const char *base, long bytes)
{
    const char *p = base;
    long n = bytes / 8;

    while (n-- > 0) {
        __asm__ __volatile__ (
            "fmove.d (%0),%%fp0"
            : : "a" (p) : "fp0");
        p += 8;
    }
    g_sinkd = 0.0;
}

static int fpu_present(void)
{
    long fpu = 0;

    if (Gestalt(gestaltFPUType, &fpu) != noErr) {
        return 0;
    }
    return fpu != gestaltNoFPU;
}

/* ---- timing one method ---------------------------------------------------- */

typedef struct {
    unsigned long first_us;   /* the first pass, cold */
    unsigned long best_us;    /* the fastest pass */
    long          bytes;      /* what the pass actually covered */
} PassResult;

static unsigned long time_one(ReadFn fn, const char *base, long bytes)
{
    unsigned long t0 = now_us();
    unsigned long t1;

    fn(base, bytes);
    t1 = now_us();
    return t1 - t0;            /* unsigned: correct across the 71 min wrap */
}

/* Calibrate on a slice, shorten the pass to fit the budget, then time it.
 * `passes` is 2 only for the method whose reread row we want; every other
 * method pays one pass, which is what keeps the whole run near ten seconds
 * instead of twenty. */
static void measure(ReadFn fn, const char *base, long full_bytes,
                    long slice_bytes, int passes, PassResult *out)
{
    unsigned long slice_us;
    int i;

    out->first_us = 0;
    out->best_us = 0;
    out->bytes = 0;

    slice_us = time_one(fn, base, slice_bytes);
    out->bytes = n68_vprobe_scaled_bytes(slice_us, slice_bytes, full_bytes,
                                         (unsigned long)kPhaseBudgetUs,
                                         kReadAlign);
    if (out->bytes <= 0) {
        return;
    }
    for (i = 0; i < passes; ++i) {
        unsigned long us = time_one(fn, base, out->bytes);

        if (i == 0) {
            out->first_us = us;
            out->best_us = us;
        } else if (us < out->best_us) {
            out->best_us = us;
        }
    }
}

/* ---- the screen ----------------------------------------------------------- */

typedef struct {
    unsigned long base;
    long          row_bytes;
    long          width;
    long          height;
    long          depth;
    long          bytes;
    long          visible_row;   /* bytes of a row that hold pixels */
    Rect          bounds;        /* global, as QuickDraw sees it */
    PixMapHandle  pix;           /* NULL when there is no Color QuickDraw */
} ScreenInfo;

static int color_qd_present(void)
{
    long qdv = 0;

    if (Gestalt(gestaltQuickdrawVersion, &qdv) != noErr) {
        return 0;
    }
    return qdv >= gestalt8BitQD;
}

/* Walks to the framebuffer FAIL-CLOSED. Two routes, because this guest
 * should say something useful on a machine without Color QuickDraw rather
 * than refuse: the GDevice's PixMap when there is one, and QuickDraw's own
 * screenBits otherwise. Whichever route produced the numbers, they go
 * through n68_vprobe_geometry_ok() before anything is dereferenced - the
 * walk is what might have landed somewhere unexpected, and on a 68030 the
 * cost of finding out by reading is the machine. */
static VProbe68Status screen_info(ScreenInfo *s, char *why, long why_cap)
{
    N68VProbeGeom geom;
    long pos = 0;

    memset(s, 0, sizeof *s);

    if (color_qd_present()) {
        GDHandle gd = GetMainDevice();

        if (gd == NULL || (**gd).gdPMap == NULL) {
            (void)now68k_fmt_append_str(why, why_cap - 1, &pos,
                                        "vprobe: this Mac has no main "
                                        "screen device");
            why[pos > 0 ? pos : 0] = '\0';
            return kVProbe68NoScreen;
        }
        s->pix = (**gd).gdPMap;
        s->base = (unsigned long)GetPixBaseAddr(s->pix);
        s->row_bytes = (long)((**s->pix).rowBytes & 0x3FFF);
        s->bounds = (**s->pix).bounds;
        s->depth = (long)(**s->pix).pixelSize;
    } else {
        s->pix = NULL;
        s->base = (unsigned long)qd.screenBits.baseAddr;
        s->row_bytes = (long)(qd.screenBits.rowBytes & 0x3FFF);
        s->bounds = qd.screenBits.bounds;
        s->depth = 1;
    }
    s->width = (long)(s->bounds.right - s->bounds.left);
    s->height = (long)(s->bounds.bottom - s->bounds.top);

    geom = n68_vprobe_geometry_ok(s->base, s->row_bytes, s->width, s->height,
                                  s->depth, &s->bytes);
    if (geom != kN68VProbeGeomOK) {
        pos = 0;
        (void)(now68k_fmt_append_str(why, why_cap - 1, &pos,
                                     "vprobe refused to read: ")
               && now68k_fmt_append_str(why, why_cap - 1, &pos,
                                        n68_vprobe_geom_reason(geom)));
        if (pos < 0 || pos >= why_cap) {
            pos = 0;
        }
        why[pos] = '\0';
        return kVProbe68Geometry;
    }
    s->visible_row = (s->width * s->depth + 7) / 8;
    return kVProbe68OK;
}

/* ---- CopyBits, a band at a time ------------------------------------------- */

typedef struct {
    GWorldPtr    world;
    PixMapHandle pix;
    short        rows;
    long         row_bytes;
    Ptr          base;
} BandWorld;

/* One band of offscreen at the screen's own depth AND with the screen's
 * own colour table. The colour table is not a detail: CopyBits between two
 * 8-bit pixmaps with different tables translates indices, which would make
 * the fidelity comparison below fail on a perfectly good copy. */
static int band_open(BandWorld *b, const ScreenInfo *s, short rows)
{
    Rect r;
    CTabHandle clut = NULL;

    memset(b, 0, sizeof *b);
    if (s->pix == NULL) {
        return 0;               /* no Color QuickDraw: no GWorld either */
    }
    if (rows > (short)s->height) {
        rows = (short)s->height;
    }
    SetRect(&r, 0, 0, (short)s->width, rows);
    if (s->depth <= 8) {
        clut = (**s->pix).pmTable;
    }
    if (NewGWorld(&b->world, (short)s->depth, &r, clut, NULL, 0) != noErr
        || b->world == NULL) {
        /* Temporary memory rather than this 384 KB partition, for the same
         * reason every offscreen in this project tries it second. */
        if (NewGWorld(&b->world, (short)s->depth, &r, clut, NULL,
                      useTempMem) != noErr || b->world == NULL) {
            return 0;
        }
    }
    b->pix = GetGWorldPixMap(b->world);
    if (b->pix == NULL || !LockPixels(b->pix)) {
        DisposeGWorld(b->world);
        b->world = NULL;
        return 0;
    }
    b->rows = rows;
    b->row_bytes = (long)((**b->pix).rowBytes & 0x3FFF);
    b->base = GetPixBaseAddr(b->pix);
    return b->base != NULL;
}

static void band_close(BandWorld *b)
{
    if (b->world != NULL) {
        if (b->pix != NULL) {
            UnlockPixels(b->pix);
        }
        DisposeGWorld(b->world);
        b->world = NULL;
        b->pix = NULL;
    }
}

/* Copies rows [top, top + b->rows) of the screen into the band, and returns
 * what the CopyBits itself cost. The port swap is outside the timed region
 * on purpose: this row is meant to be comparable with a raw read of the
 * same bytes, not with a whole capture pipeline.
 *
 * NOT QUITE THE POWERPC GUEST'S CopyBits ROW, and worth knowing before the
 * two are compared. That one blits the whole screen in one call into a
 * full-frame GWorld; this one blits fifteen bands into a 20 KB GWorld,
 * because 300 KB of offscreen does not fit a 384 KB partition. The sum
 * therefore carries fifteen call overheads that the 1400c's number does
 * not - it is the honest cost of a BANDED capture on this machine, which
 * is the only kind this machine can do. */
static unsigned long band_copy(BandWorld *b, const ScreenInfo *s, long top)
{
    CGrafPtr  save_port;
    GDHandle  save_device;
    Rect      src;
    Rect      dst;
    unsigned long t0;
    unsigned long t1;

    src = s->bounds;
    src.top = (short)(s->bounds.top + top);
    src.bottom = (short)(src.top + b->rows);
    SetRect(&dst, 0, 0, (short)s->width, b->rows);

    GetGWorld(&save_port, &save_device);
    SetGWorld(b->world, NULL);
    ForeColor(blackColor);
    BackColor(whiteColor);
    /* The screen PixMap is dereferenced straight into the call with no
     * allocation in between, and it is NOT locked here: it belongs to the
     * GDevice, the system keeps it where it wants it, and an HUnlock of a
     * handle this code did not lock would clear a lock bit that was not
     * ours to clear. */
    t0 = now_us();
    CopyBits((BitMap *)*s->pix, (BitMap *)*b->pix, &src, &dst, srcCopy, NULL);
    t1 = now_us();
    SetGWorld(save_port, save_device);
    return t1 - t0;
}

/* ---- the run -------------------------------------------------------------- */

/* `passes` is 2 for exactly one method - the 32-bit read, whose two passes
 * ARE the reread row. Every other method pays one pass, which is what
 * keeps the whole run near ten seconds rather than twenty on a machine
 * nobody has measured yet. The PowerPC guest could afford best-of-two
 * everywhere; at 33 MHz that is a second and a half per extra pass. */
static const struct {
    const char *label;
    ReadFn      fn;
    int         passes;
} k_methods[] = {
    { "Raw 8-bit",  read8,      1 },
    { "Raw 16-bit", read16,     1 },
    { "Raw 32-bit", read32,     2 },
    { "Raw 32 x8",  read32u8,   1 },
    { "movem.l x8", read_movem, 1 }
};

/* Bytes per millisecond - the comparison the "Best raw" row is picked by.
 * Kept small deliberately: bytes * 1000 stays inside 32 bits for any frame
 * this machine has, while bytes * 1000000 would not. */
static unsigned long rate_bpms(long bytes, unsigned long us)
{
    if (us == 0UL || bytes <= 0) {
        return 0UL;
    }
    return (unsigned long)bytes * 1000UL / us;
}

VProbe68Status vprobe68_run(N68VProbeTable *t, char *why, long why_cap)
{
    ScreenInfo s;
    VProbe68Status status;
    PassResult pass;
    char value[kN68VProbeValueCap];
    char label[kN68VProbeLabelCap];
    long slice_bytes;
    long pos;
    unsigned long run_t0;
    unsigned long reread_first = 0;
    unsigned long reread_best = 0;
    long reread_bytes = 0;
    unsigned long best_rate = 0;
    const char *best_label = NULL;
    unsigned long best_us = 0;
    long best_bytes = 0;
    int i;

    if (t == NULL || why == NULL || why_cap <= 0) {
        return kVProbe68Geometry;
    }
    why[0] = '\0';
    n68_vprobe_table_init(t);

    if (g_running) {
        pos = 0;
        (void)now68k_fmt_append_str(why, why_cap - 1, &pos,
                                    "vprobe is already running on this Mac");
        why[pos > 0 ? pos : 0] = '\0';
        return kVProbe68Busy;
    }
    g_running = true;
    run_t0 = now_us();

    status = screen_info(&s, why, why_cap);
    if (status != kVProbe68OK) {
        g_running = false;
        return status;
    }

    /* --- what was measured, before anything measured ---------------------- */
    pos = 0;
    (void)(now68k_fmt_append_long(value, (long)sizeof value - 1, &pos, s.width)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos, "x")
           && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                     s.height)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                    " - ")
           && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                     s.depth)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                    "-bit"));
    value[pos > 0 ? pos : 0] = '\0';
    (void)n68_vprobe_add(t, NOW68K_VPROBE_SCREEN_LABEL, value);

    /* The base address is worth a row of its own: it is the first thing
     * anyone comparing this run against another machine's wants, and on a
     * 68030 it is also the number a crash would have been about. Hex by
     * hand - numfmt.h has no hex and this is the only caller. */
    {
        static const char kHex[] = "0123456789ABCDEF";
        char hex[11];
        int d;

        hex[0] = '0';
        hex[1] = 'x';
        for (d = 0; d < 8; ++d) {
            hex[2 + d] = kHex[(s.base >> (28 - 4 * d)) & 0xFUL];
        }
        hex[10] = '\0';
        pos = 0;
        (void)(now68k_fmt_append_str(value, (long)sizeof value - 1, &pos, hex)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " rowBytes ")
               && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                         s.row_bytes));
        value[pos > 0 ? pos : 0] = '\0';
        (void)n68_vprobe_add(t, "Framebuffer", value);
    }

    pos = 0;
    (void)(now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                  s.bytes / 1024L)
           && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                    " KB/frame"));
    value[pos > 0 ? pos : 0] = '\0';
    (void)n68_vprobe_add(t, "Volume", value);

    /* --- the clock, before anything is timed with it ---------------------- */
    {
        long dups = 0;
        unsigned long step = timer_step_us((long)kTimerSamples, &dups);

        pos = 0;
        (void)(now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                     "min ")
               && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                         (long)step)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " us, ")
               && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                         dups)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        "/")
               && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                         (long)kTimerSamples)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " same"));
        value[pos > 0 ? pos : 0] = '\0';
        (void)n68_vprobe_add(t, "Timer", value);
    }
    vprobe_pump();

    /* --- CopyBits baseline at native depth -------------------------------- */
    {
        BandWorld band;

        if (band_open(&band, &s, (short)kBandRows)) {
            unsigned long total = 0;
            long covered = 0;
            long top;

            for (top = 0; top + band.rows <= s.height; top += band.rows) {
                total += band_copy(&band, &s, top);
                covered += (long)band.rows * s.row_bytes;
                if (total >= (unsigned long)kPhaseBudgetUs) {
                    break;      /* bounded like every other phase */
                }
                vprobe_pump();
            }
            band_close(&band);
            n68_vprobe_bw_value(value, (long)sizeof value, covered, s.bytes,
                                total);
        } else {
            /* No Color QuickDraw, or no room for 20 KB of offscreen. The
             * raw rows below are still the point of the run, so this is a
             * missing baseline rather than a failed probe. */
            (void)strcpy(value, "no offscreen band");
        }
        (void)n68_vprobe_add(t, "CopyBits", value);
    }
    vprobe_pump();

    /* --- the raw methods --------------------------------------------------- */
    slice_bytes = s.row_bytes * (long)kSliceRows;
    slice_bytes -= slice_bytes % kReadAlign;
    if (slice_bytes <= 0 || slice_bytes > s.bytes) {
        slice_bytes = s.bytes - (s.bytes % kReadAlign);
    }

    for (i = 0; i < (int)(sizeof k_methods / sizeof k_methods[0]); ++i) {
        measure(k_methods[i].fn, (const char *)s.base, s.bytes, slice_bytes,
                k_methods[i].passes, &pass);
        n68_vprobe_bw_value(value, (long)sizeof value, pass.bytes, s.bytes,
                            pass.best_us);
        (void)n68_vprobe_add(t, k_methods[i].label, value);
        if (k_methods[i].passes > 1) {
            reread_first = pass.first_us;
            reread_best = pass.best_us;
            reread_bytes = pass.bytes;
        }
        if (rate_bpms(pass.bytes, pass.best_us) > best_rate) {
            best_rate = rate_bpms(pass.bytes, pass.best_us);
            best_label = k_methods[i].label;
            best_us = pass.best_us;
            best_bytes = pass.bytes;
        }
        vprobe_pump();
    }

    /* --- the 68882 --------------------------------------------------------- */
    if (!fpu_present()) {
        (void)n68_vprobe_add(t, "fmove.d fp", "skipped (no FPU)");
    } else if ((s.base & 7UL) != 0UL) {
        (void)n68_vprobe_add(t, "fmove.d fp", "skipped (base not 8-aligned)");
    } else {
        measure(read_fp64, (const char *)s.base, s.bytes, slice_bytes, 1,
                &pass);
        n68_vprobe_bw_value(value, (long)sizeof value, pass.bytes, s.bytes,
                            pass.best_us);
        (void)n68_vprobe_add(t, "fmove.d fp", value);
        if (rate_bpms(pass.bytes, pass.best_us) > best_rate) {
            best_rate = rate_bpms(pass.bytes, pass.best_us);
            best_label = "fmove.d fp";
            best_us = pass.best_us;
            best_bytes = pass.bytes;
        }
    }
    vprobe_pump();

    /* --- the headline ------------------------------------------------------ */
    /* Which method won and how fast, in one row, because this is the row
     * the CONSOLE gets: n68_vprobe_summary() picks it out by label, and an
     * N68CmdResult can carry two rows in total. Rate only, no milliseconds
     * and no percentage - at 29 bytes the method's name and its MB/s are
     * what fit, and they are what a person standing at the machine wants. */
    if (best_label != NULL) {
        char rate[16];
        long mp = 0;

        n68_vprobe_rate_value(rate, (long)sizeof rate, best_bytes, best_us);
        (void)(now68k_fmt_append_str(value, (long)sizeof value - 1, &mp,
                                     best_label)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &mp,
                                        " ")
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &mp,
                                        rate));
        value[mp > 0 && mp < (long)sizeof value ? mp : 0] = '\0';
        (void)n68_vprobe_add(t, NOW68K_VPROBE_BEST_LABEL, value);
    } else {
        (void)n68_vprobe_add(t, NOW68K_VPROBE_BEST_LABEL, "nothing measured");
    }

    /* --- reread: is the framebuffer cached? -------------------------------- */
    {
        char first_ms[12];
        char best_ms[12];

        n68_vprobe_ms_value(first_ms, (long)sizeof first_ms, reread_first);
        n68_vprobe_ms_value(best_ms, (long)sizeof best_ms, reread_best);
        pos = 0;
        (void)(now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                     "1st ")
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        first_ms)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " / best ")
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        best_ms)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " ms"));
        value[pos > 0 ? pos : 0] = '\0';
        (void)n68_vprobe_add(t, "Reread 32", value);
    }

    /* --- partial-read linearity -------------------------------------------- */
    {
        long part_rows = s.height / (long)kPartialDivisor;
        long part_bytes = s.row_bytes * part_rows;
        unsigned long measured = 0;
        unsigned long predicted;
        char got[12];
        char want[12];
        int k;

        part_bytes -= part_bytes % kReadAlign;
        if (part_bytes > 0) {
            for (k = 0; k < (int)kPartialTries; ++k) {
                unsigned long us = time_one(read32, (const char *)s.base,
                                            part_bytes);

                if (measured == 0 || us < measured) {
                    measured = us;
                }
            }
        }
        predicted = n68_vprobe_predict_us(reread_best, reread_bytes,
                                          part_bytes);
        n68_vprobe_ms_value(got, (long)sizeof got, measured);
        n68_vprobe_ms_value(want, (long)sizeof want, predicted);
        pos = 0;
        (void)(now68k_fmt_append_str(label, (long)sizeof label - 1, &pos,
                                     "Partial ")
               && now68k_fmt_append_long(label, (long)sizeof label - 1, &pos,
                                         part_rows)
               && now68k_fmt_append_str(label, (long)sizeof label - 1, &pos,
                                        " rows"));
        label[pos > 0 ? pos : 0] = '\0';
        pos = 0;
        (void)(now68k_fmt_append_str(value, (long)sizeof value - 1, &pos, got)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " ms, want ")
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        want));
        value[pos > 0 ? pos : 0] = '\0';
        (void)n68_vprobe_add(t, label, value);
    }
    vprobe_pump();

    /* --- fidelity: does a raw read see what CopyBits copies? ---------------- */
    {
        BandWorld band;

        if (band_open(&band, &s, (short)kBandRows)) {
            unsigned long started = now_us();
            long compared = 0;
            long differ = 0;
            long first_diff = -1;
            long top;

            /* THE ONE PHASE THAT DOES NOT PUMP, and the one bounded by the
             * WALL CLOCK rather than by the time inside the calls. It does
             * not pump because a pumped update event would repaint part of
             * the screen between the copy and the comparison, and every
             * repainted row would read as a fidelity failure - the cursor
             * is hidden here for exactly the same reason. So it is bounded
             * by elapsed time including the memcmp (which reads the
             * framebuffer a second time and is not free), and the row says
             * how many rows it actually got through. */
            HideCursor();       /* so the cursor cannot differ between looks */
            for (top = 0; top + band.rows <= s.height; top += band.rows) {
                long r;

                (void)band_copy(&band, &s, top);
                for (r = 0; r < (long)band.rows; ++r) {
                    const char *screen_row =
                        (const char *)s.base + (top + r) * s.row_bytes;
                    const char *band_row = band.base + r * band.row_bytes;

                    ++compared;
                    if (memcmp(screen_row, band_row,
                               (size_t)s.visible_row) != 0) {
                        ++differ;
                        if (first_diff < 0) {
                            first_diff = top + r;
                        }
                    }
                }
                if (now_us() - started >= (unsigned long)kPhaseBudgetUs) {
                    break;
                }
            }
            ShowCursor();
            band_close(&band);

            pos = 0;
            if (differ == 0) {
                (void)(now68k_fmt_append_str(value, (long)sizeof value - 1,
                                             &pos, "MATCH (")
                       && now68k_fmt_append_long(value,
                                                 (long)sizeof value - 1,
                                                 &pos, compared)
                       && now68k_fmt_append_str(value, (long)sizeof value - 1,
                                                &pos, " rows)"));
            } else {
                (void)(now68k_fmt_append_long(value, (long)sizeof value - 1,
                                              &pos, differ)
                       && now68k_fmt_append_str(value, (long)sizeof value - 1,
                                                &pos, "/")
                       && now68k_fmt_append_long(value,
                                                 (long)sizeof value - 1,
                                                 &pos, compared)
                       && now68k_fmt_append_str(value, (long)sizeof value - 1,
                                                &pos, " differ, 1st ")
                       && now68k_fmt_append_long(value,
                                                 (long)sizeof value - 1,
                                                 &pos, first_diff));
            }
            value[pos > 0 ? pos : 0] = '\0';
        } else {
            (void)strcpy(value, "no offscreen band");
        }
        (void)n68_vprobe_add(t, "Fidelity", value);
    }

    /* --- what the run itself cost ------------------------------------------ */
    {
        char ms[12];

        n68_vprobe_ms_value(ms, (long)sizeof ms, now_us() - run_t0);
        pos = 0;
        (void)(now68k_fmt_append_str(value, (long)sizeof value - 1, &pos, ms)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " ms, ")
               && now68k_fmt_append_long(value, (long)sizeof value - 1, &pos,
                                         (long)t->count + 1)
               && now68k_fmt_append_str(value, (long)sizeof value - 1, &pos,
                                        " rows"));
        value[pos > 0 ? pos : 0] = '\0';
        (void)n68_vprobe_add(t, "Run", value);
    }

    if (t->dropped > 0) {
        now68k_log_num("vprobe: rows dropped, table full", (long)t->dropped);
    }
    g_running = false;
    return kVProbe68OK;
}
