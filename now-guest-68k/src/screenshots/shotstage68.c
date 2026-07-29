/*
 * shotstage68.c - implementation of shotstage68.h. Read that header
 * first: it carries why a capture is staged at all, and that the staged
 * file IS the bulk payload rather than an intermediate format.
 *
 * STATIC BUDGET (file-scope BSS - these are too big for a 68K stack frame
 * reachable from a pumped nested dispatch, and there is exactly one
 * capture in flight):
 *   g_row      one screen row                                 640 bytes
 *   g_packed   one packed row, at the PackBits BOUND          645 bytes
 *   g_io       the write buffer                              1024 bytes
 *   g_palette  the screen's CLUT, snapshotted once            768 bytes
 *   g_running  re-entry guard                                   2 bytes
 *   ------------------------------------------------------------------
 *   total                                                   ~3.1 KB
 * It never holds a band, let alone a frame.
 *
 * No printf family (numfmt.h only).
 */
#include "shotstage68.h"

#include "log.h"
#include "n68_packbits.h"
#include "numfmt.h"
#include "n68_putfile.h"   /* now68k_desktop_folder - ONE root */
#include "screen68.h"

#include <Files.h>
#include <Folders.h>
#include <LowMem.h>       /* LMGetMMU32Bit - see sample_addressing() */
#include <MacMemory.h>    /* StripAddress */
#include <Quickdraw.h>

#include <string.h>

enum {
    kStageMaxRow = 1024,        /* widest screen row this will stage */
    kStageIOBuf  = 1024
};

static unsigned char g_row[kStageMaxRow];
static unsigned char g_packed[kStageMaxRow + kStageMaxRow / 128 + 2];
static char          g_io[kStageIOBuf];
static unsigned char g_palette[kN68ShotWirePaletteBytes];
static long          g_io_n;
static short         g_ref;
static OSErr         g_err;
static long          g_written;
static unsigned long g_write_us;
static Boolean       g_running = false;

/* Buffered writes, for the same reason shot68.c buffers its picture: the
 * File Manager is called once per kilobyte rather than once per row. */
static void stage_flush(void)
{
    long count = g_io_n;
    unsigned long t0;

    if (count <= 0 || g_ref == 0) {
        g_io_n = 0;
        return;
    }
    g_io_n = 0;
    t0 = screen68_micros();
    if (g_err == noErr) {
        OSErr e = FSWrite(g_ref, &count, g_io);

        if (e != noErr) {
            g_err = e;
        }
    }
    g_write_us += screen68_micros() - t0;
}

static void stage_put(const void *bytes, long n)
{
    const char *p = (const char *)bytes;

    g_written += n;
    while (n > 0) {
        long room = (long)sizeof g_io - g_io_n;
        long take = n < room ? n : room;

        memcpy(g_io + g_io_n, p, (size_t)take);
        g_io_n += take;
        p += take;
        n -= take;
        if (g_io_n >= (long)sizeof g_io) {
            stage_flush();
        }
    }
}

/* ---- the sink the walk hands its bytes to -------------------------------
 *
 * The walk itself is n68_shotwire_emit(), which has no Toolbox in it and
 * is driven over a synthetic framebuffer by test_shotemit.c. What stays
 * here is the three things only this machine can do: buffer to a file,
 * hide the cursor over the row being read, and time the two halves. */
typedef struct {
    Rect          bounds;        /* the screen's, for the shield rect */
    unsigned long t0;
    unsigned long t_read;
    unsigned long t_pack;
    unsigned long base;          /* the walk's own base, for the diagnostic */
    N68ShotDiag  *diag;          /* NULL on the ordinary path */
} StageCtx;

/* THE INSTANT THIS IS READ IS THE WHOLE POINT (n68_shotdiag.h). It is
 * sampled from inside the walk's first row, which is AFTER the scratch
 * file has been created and opened - so if the File Manager or the disk
 * driver left this machine in 24-bit addressing, this is where it shows.
 * A probe that samples it before opening a file cannot see that, which is
 * why `vprobe` reporting a clean fidelity sweep did not settle anything.
 *
 * LMGetMMU32Bit() rather than GetMMUMode(): they read the same low-memory
 * byte (0x0CB2), but Universal Interfaces declares the low-memory
 * accessor as an inline and lists GetMMUMode among the calls that need
 * glue, and a diagnostic that fails to LINK is worth nothing. */
static void sample_addressing(N68ShotDiag *diag, unsigned long base)
{
    if (diag == NULL) {
        return;
    }
    diag->base = base;
    diag->stripped = (unsigned long)StripAddress((void *)base);
    diag->mmu32 = LMGetMMU32Bit() != 0;
}

static void stage_sink_put(void *ctx, const void *bytes, long n)
{
    (void)ctx;
    stage_put(bytes, n);
}

static void stage_sink_row_begin(void *ctx, long row)
{
    StageCtx *sc = (StageCtx *)ctx;
    Rect shield;
    Point zero;

    if (row == 0) {
        sample_addressing(sc->diag, sc->base);
    }
    /* Shielded per row, for shotsrc68.h's reason: a whole-transfer hide
     * takes the cursor away from the person at the machine. */
    shield = sc->bounds;
    shield.top = (short)(sc->bounds.top + row);
    shield.bottom = (short)(shield.top + 1);
    zero.h = 0;
    zero.v = 0;
    sc->t0 = screen68_micros();
    ShieldCursor(&shield, zero);
}

static void stage_sink_row_read(void *ctx, long row)
{
    StageCtx *sc = (StageCtx *)ctx;

    /* The bytes the capture ACTUALLY sent, taken out of the same buffer
     * PackBits is about to read - not a second read of the same address,
     * which could differ and would then be describing a capture nobody
     * received. */
    if (row == 0 && sc->diag != NULL) {
        memcpy(sc->diag->walk, g_row, (size_t)kN68ShotDiagSampleBytes);
        sc->diag->walk_ok = 1;
    }
    ShowCursor();
    sc->t_read += screen68_micros() - sc->t0;
    sc->t0 = screen68_micros();
}

static void stage_sink_row_packed(void *ctx, long row)
{
    StageCtx *sc = (StageCtx *)ctx;

    (void)row;
    sc->t_pack += screen68_micros() - sc->t0;
}

static int stage_sink_stop(void *ctx)
{
    (void)ctx;
    return g_err != noErr;
}

static void say(char *why, long why_cap, const char *text)
{
    long pos = 0;

    if (why == NULL || why_cap <= 0) {
        return;
    }
    (void)now68k_fmt_append_str(why, why_cap - 1, &pos, text);
    why[pos > 0 && pos < why_cap ? pos : 0] = '\0';
}

static void say_num(char *why, long why_cap, const char *before, long n,
                    const char *after)
{
    long pos = 0;

    if (why == NULL || why_cap <= 0) {
        return;
    }
    (void)(now68k_fmt_append_str(why, why_cap - 1, &pos, before)
           && now68k_fmt_append_long(why, why_cap - 1, &pos, n)
           && now68k_fmt_append_str(why, why_cap - 1, &pos, after));
    why[pos > 0 && pos < why_cap ? pos : 0] = '\0';
}

static void leaf_pascal(Str255 dst)
{
    const char *src = kShotStageLeaf;
    long n = 0;

    while (src[n] != '\0' && n < 31) {
        dst[n + 1] = (unsigned char)src[n];
        ++n;
    }
    dst[0] = (unsigned char)n;
}

/* The scratch file lives in the PUBLISHED ROOT, not beside the
 * application, because that is where the file source looks.
 *
 * This cost an emulator round trip to find, and it is the second time
 * this exact mistake has been made in this tree: the send and receive
 * halves were briefly split across two roots too, and n68_putfile.h
 * records that only a real file system could notice ("every native test
 * passed and no conflict marked"). Staging wrote beside the application
 * and n68_filesrc read from the Desktop, so the capture staged perfectly
 * and then could not be found. now68k_desktop_folder() is the one place
 * the root is decided, for both directions and now for this. */
static OSErr stage_spec(FSSpec *spec)
{
    short vref = 0;
    long dir = 0;
    Str255 pname;

    if (!now68k_desktop_folder(&vref, &dir)) {
        return dirNFErr;
    }
    leaf_pascal(pname);
    return FSMakeFSSpec(vref, dir, pname, spec);
}

void shotstage68_discard(void)
{
    FSSpec spec;

    if (stage_spec(&spec) == noErr || stage_spec(&spec) == fnfErr) {
        (void)FSpDelete(&spec);
    }
}

/* The second opinion, taken as a PAIR and with nothing pumped between the
 * two reads: one CopyBits band of row 0, and one fresh walk of the same
 * row. Comparing those two answers "is the base right"; comparing the
 * fresh walk against the one the capture took answers "did the screen hold
 * still", which is what makes the first answer quotable. n68_shotdiag.h
 * carries the argument.
 *
 * A band this small (one row, 640 bytes at 8 bits) is the cheapest thing
 * screen68_band_open is ever asked for, but it can still fail on a 384 KB
 * partition - and a failure is reported as one rather than folded into a
 * pass. */
static void sample_pair(N68ShotDiag *diag, const Screen68 *sc)
{
    Band68 band;

    if (diag == NULL) {
        return;
    }
    if (!screen68_band_open(&band, sc, 1)) {
        return;
    }
    HideCursor();      /* so the cursor cannot differ between the two looks */
    (void)screen68_band_copy(&band, sc, 0);
    memcpy(diag->blit, band.base, (size_t)kN68ShotDiagSampleBytes);
    memcpy(diag->walk_again, (const void *)sc->base,
           (size_t)kN68ShotDiagSampleBytes);
    ShowCursor();
    screen68_band_close(&band);
    diag->pair_ok = 1;
}

ShotStage68Status shotstage68_write(ShotStage68 *out, char *why, long why_cap)
{
    return shotstage68_diagnose(out, NULL, why, why_cap);
}

ShotStage68Status shotstage68_diagnose(ShotStage68 *out, N68ShotDiag *diag,
                                       char *why, long why_cap)
{
    Screen68 sc;
    FSSpec spec;
    OSErr err;
    StageCtx stage;
    N68ShotWireSink sink;
    long emitted;
    long i;

    if (out == NULL || why == NULL || why_cap <= 0) {
        return kShotStage68Geometry;
    }
    memset(out, 0, sizeof *out);
    n68_shotdiag_init(diag);
    why[0] = '\0';

    if (g_running) {
        say(why, why_cap, "a capture is already being staged on this Mac");
        return kShotStage68File;
    }

    switch (screen68_info(&sc, "capture", why, why_cap)) {
    case kScreen68OK:
        break;
    case kScreen68NoScreen:
        return kShotStage68NoScreen;
    default:
        return kShotStage68Geometry;
    }
    if (!n68_shotwire_plan(sc.width, sc.height, sc.depth, &out->plan)) {
        say_num(why, why_cap, "this lane sends 8-bit screens only; this one is ",
                sc.depth, "-bit");
        return kShotStage68Depth;
    }
    if (out->plan.row_bytes > (long)sizeof g_row) {
        say_num(why, why_cap, "this screen's rows are ", out->plan.row_bytes,
                " bytes, wider than the capture stage holds");
        return kShotStage68Geometry;
    }

    if (diag != NULL) {
        diag->width = out->plan.width;
        diag->height = out->plan.height;
        diag->depth = out->plan.depth;
        diag->fb_row_bytes = sc.row_bytes;
        diag->row_bytes = out->plan.row_bytes;
        /* The addressing sample is taken again inside the walk; this one
         * exists so a run that never reaches the walk (no disk, no room)
         * still says where the screen was said to be. */
        sample_addressing(diag, sc.base);
    }

    g_running = true;
    g_io_n = 0;
    g_ref = 0;
    g_err = noErr;
    g_written = 0;
    g_write_us = 0;

    /* Recreated every time: a stale capture from a previous transfer would
     * otherwise be appended to and sent as this one. */
    /* stage_spec's RETURN IS CHECKED, and it was not before. fnfErr is the
     * ordinary answer - the scratch file does not exist yet and the FSSpec
     * is fully built anyway, which is exactly what FSpCreate wants. Any
     * other failure means `spec` was never filled in, and the old code
     * then handed an uninitialised stack FSSpec to FSpDelete and FSpCreate:
     * a random vRefNum, dirID and name, acted on by the File Manager. It
     * has never been seen to fire (it needs now68k_desktop_folder to fail,
     * or the volume to go away between the two calls) and it is one line
     * to close, which is the whole argument for closing it. */
    err = stage_spec(&spec);
    if (err != noErr && err != fnfErr) {
        g_running = false;
        say_num(why, why_cap, "could not name the capture file (error ",
                (long)err, ")");
        return kShotStage68File;
    }
    (void)FSpDelete(&spec);
    err = FSpCreate(&spec, 'NW68', 'BINA', smSystemScript);
    if (err == noErr) {
        err = FSpOpenDF(&spec, fsRdWrPerm, &g_ref);
    }
    if (err != noErr) {
        g_ref = 0;
        g_running = false;
        say_num(why, why_cap, "could not stage the capture (error ",
                (long)err, ")");
        return kShotStage68File;
    }

    /* The palette, narrowed to 8 bits a channel exactly as shotsrc68.c
     * does - two senders of the same stream must agree on what an entry
     * means. Snapshotted before the walk rather than read inside it: a
     * table that changed mid-capture would describe some rows and not
     * others. */
    {
        CTabHandle clut = (sc.pix != NULL) ? (**sc.pix).pmTable : NULL;

        memset(g_palette, 0, sizeof g_palette);
        for (i = 0; i < kN68ShotWirePaletteEntries; ++i) {
            if (clut == NULL || *clut == NULL || i > (long)(**clut).ctSize) {
                continue;
            }
            g_palette[i * 3 + 0] =
                (unsigned char)((**clut).ctTable[i].rgb.red >> 8);
            g_palette[i * 3 + 1] =
                (unsigned char)((**clut).ctTable[i].rgb.green >> 8);
            g_palette[i * 3 + 2] =
                (unsigned char)((**clut).ctTable[i].rgb.blue >> 8);
        }
    }

    memset(&stage, 0, sizeof stage);
    stage.bounds = sc.bounds;
    stage.base = sc.base;
    stage.diag = diag;

    memset(&sink, 0, sizeof sink);
    sink.ctx = &stage;
    sink.put = stage_sink_put;
    sink.row_begin = stage_sink_row_begin;
    sink.row_read = stage_sink_row_read;
    sink.row_packed = stage_sink_row_packed;
    sink.stop = stage_sink_stop;
    sink.row_buf = g_row;
    sink.row_cap = (long)sizeof g_row;
    sink.pack_buf = g_packed;
    sink.pack_cap = (long)sizeof g_packed;

    /* sc.row_bytes is the screen's OWN stride; out->plan.row_bytes is the
     * visible part the host was promised. Handing both over is the whole
     * point of the split. */
    emitted = n68_shotwire_emit(&out->plan,
                                (const unsigned char *)sc.base, sc.row_bytes,
                                g_palette, (long)sizeof g_palette, &sink);
    if (emitted < 0 && g_err == noErr) {
        g_err = paramErr;
    }

    stage_flush();
    FSClose(g_ref);
    g_ref = 0;

    if (g_err != noErr) {
        shotstage68_discard();
        g_running = false;
        say_num(why, why_cap, "the staged capture could not be written "
                "(error ", (long)g_err, ")");
        return kShotStage68File;
    }

    out->total = g_written;
    out->plan.total = g_written;      /* what capture.begin promises */
    out->raw_bytes = out->plan.palette_bytes
                     + out->plan.row_bytes * out->plan.height;
    out->capture_ms = (long)(stage.t_read / 1000UL);
    out->encode_ms = (long)(stage.t_pack / 1000UL);
    out->write_ms = (long)(g_write_us / 1000UL);
    memcpy(out->leaf, kShotStageLeaf, sizeof kShotStageLeaf);
    now68k_log_num("stage: packed bytes", out->total);
    if (diag != NULL) {
        diag->staged_bytes = out->total;
        /* AFTER the file is closed, so the band's memory is asked for at
         * the moment of least pressure rather than while the write buffer
         * and an open fork are both live on a 4 MB machine. */
        sample_pair(diag, &sc);
    }
    g_running = false;
    return kShotStage68OK;
}
