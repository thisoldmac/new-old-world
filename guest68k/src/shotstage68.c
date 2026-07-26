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
 *   g_running  re-entry guard                                   2 bytes
 *   ------------------------------------------------------------------
 *   total                                                   ~2.3 KB
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
#include <Quickdraw.h>

#include <string.h>

enum {
    kStageMaxRow = 1024,        /* widest screen row this will stage */
    kStageIOBuf  = 1024
};

static unsigned char g_row[kStageMaxRow];
static unsigned char g_packed[kStageMaxRow + kStageMaxRow / 128 + 2];
static char          g_io[kStageIOBuf];
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

ShotStage68Status shotstage68_write(ShotStage68 *out, char *why, long why_cap)
{
    Screen68 sc;
    FSSpec spec;
    OSErr err;
    Rect shield;
    Point zero;
    unsigned long t_read = 0;
    unsigned long t_pack = 0;
    unsigned long t0;
    long row;
    long i;

    if (out == NULL || why == NULL || why_cap <= 0) {
        return kShotStage68Geometry;
    }
    memset(out, 0, sizeof *out);
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

    g_running = true;
    g_io_n = 0;
    g_ref = 0;
    g_err = noErr;
    g_written = 0;
    g_write_us = 0;

    /* Recreated every time: a stale capture from a previous transfer would
     * otherwise be appended to and sent as this one. */
    (void)stage_spec(&spec);
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
     * means. */
    {
        CTabHandle clut = (sc.pix != NULL) ? (**sc.pix).pmTable : NULL;
        unsigned char entry[3];

        for (i = 0; i < kN68ShotWirePaletteEntries; ++i) {
            entry[0] = entry[1] = entry[2] = 0;
            if (clut != NULL && *clut != NULL
                && i <= (long)(**clut).ctSize) {
                entry[0] = (unsigned char)((**clut).ctTable[i].rgb.red >> 8);
                entry[1] = (unsigned char)((**clut).ctTable[i].rgb.green >> 8);
                entry[2] = (unsigned char)((**clut).ctTable[i].rgb.blue >> 8);
            }
            stage_put(entry, 3);
        }
    }

    zero.h = 0;
    zero.v = 0;
    for (row = 0; row < sc.height && g_err == noErr; ++row) {
        const unsigned char *src = (const unsigned char *)sc.base
                                   + row * sc.row_bytes;
        long packed;
        unsigned char len_be[2];

        /* Shielded per row, for shotsrc68.h's reason: a whole-transfer
         * hide takes the cursor away from the person at the machine. */
        shield = sc.bounds;
        shield.top = (short)(sc.bounds.top + row);
        shield.bottom = (short)(shield.top + 1);
        t0 = screen68_micros();
        ShieldCursor(&shield, zero);
        memcpy(g_row, src, (size_t)out->plan.row_bytes);
        ShowCursor();
        t_read += screen68_micros() - t0;

        t0 = screen68_micros();
        packed = n68_packbits_row(g_row, out->plan.row_bytes, g_packed,
                                  (long)sizeof g_packed);
        t_pack += screen68_micros() - t0;
        if (packed < 0) {
            g_err = paramErr;    /* unreachable: g_packed is at the bound */
            break;
        }
        len_be[0] = (unsigned char)((packed >> 8) & 0xFF);
        len_be[1] = (unsigned char)(packed & 0xFF);
        stage_put(len_be, 2);
        stage_put(g_packed, packed);
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
    out->capture_ms = (long)(t_read / 1000UL);
    out->encode_ms = (long)(t_pack / 1000UL);
    out->write_ms = (long)(g_write_us / 1000UL);
    memcpy(out->leaf, kShotStageLeaf, sizeof kShotStageLeaf);
    now68k_log_num("stage: packed bytes", out->total);
    g_running = false;
    return kShotStage68OK;
}
