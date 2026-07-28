/*
 * screen68.c - implementation of screen68.h.
 *
 * Moved here from vprobe68.c when screenshot became the second caller.
 * The bodies are that file's, verbatim in behaviour; what changed is that
 * the refusal sentences name their caller (`who`) instead of hard-coding
 * "vprobe", and the status enum is this file's rather than vprobe's.
 *
 * STATIC BUDGET: none. This file owns no BSS and allocates nothing except
 * the one band GWorld, which its caller opens and closes by name.
 *
 * No printf family (numfmt.h only, matching the rest of now-guest-68k/src).
 */
#include "screen68.h"

#include "n68_vprobe.h"
#include "numfmt.h"

#include <Gestalt.h>
#include <Timer.h>

#include <string.h>

unsigned long screen68_micros(void)
{
    UnsignedWide t;

    Microseconds(&t);
    return t.lo;
}

static int color_qd_present(void)
{
    long qdv = 0;

    if (Gestalt(gestaltQuickdrawVersion, &qdv) != noErr) {
        return 0;
    }
    return qdv >= gestalt8BitQD;
}

Screen68Status screen68_info(Screen68 *s, const char *who,
                             char *why, long why_cap)
{
    N68VProbeGeom geom;
    long pos = 0;

    memset(s, 0, sizeof *s);
    if (who == NULL) {
        who = "this Mac";
    }

    if (color_qd_present()) {
        GDHandle gd = GetMainDevice();

        if (gd == NULL || (**gd).gdPMap == NULL) {
            (void)(now68k_fmt_append_str(why, why_cap - 1, &pos, who)
                   && now68k_fmt_append_str(why, why_cap - 1, &pos,
                                            ": this Mac has no main "
                                            "screen device"));
            why[pos > 0 ? pos : 0] = '\0';
            return kScreen68NoScreen;
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
        (void)(now68k_fmt_append_str(why, why_cap - 1, &pos, who)
               && now68k_fmt_append_str(why, why_cap - 1, &pos,
                                        " refused to read: ")
               && now68k_fmt_append_str(why, why_cap - 1, &pos,
                                        n68_vprobe_geom_reason(geom)));
        if (pos < 0 || pos >= why_cap) {
            pos = 0;
        }
        why[pos] = '\0';
        return kScreen68Geometry;
    }
    s->visible_row = (s->width * s->depth + 7) / 8;
    return kScreen68OK;
}

int screen68_band_open(Band68 *b, const Screen68 *s, short rows)
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

void screen68_band_close(Band68 *b)
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

/* NOT QUITE THE POWERPC GUEST'S CopyBits ROW, and worth knowing before the
 * two are compared. That one blits the whole screen in one call into a
 * full-frame GWorld; this one blits fifteen bands into a 20 KB GWorld,
 * because 300 KB of offscreen does not fit a 384 KB partition. The sum
 * therefore carries fifteen call overheads that the 1400c's number does
 * not - it is the honest cost of a BANDED capture on this machine, which
 * is the only kind this machine can do. */
unsigned long screen68_band_copy(Band68 *b, const Screen68 *s, long top)
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
    t0 = screen68_micros();
    CopyBits((BitMap *)*s->pix, (BitMap *)*b->pix, &src, &dst, srcCopy, NULL);
    t1 = screen68_micros();
    SetGWorld(save_port, save_device);
    return t1 - t0;
}
