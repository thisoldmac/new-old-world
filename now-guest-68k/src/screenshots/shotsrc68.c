/*
 * shotsrc68.c - implementation of shotsrc68.h. Read that header first: it
 * carries why this reads the framebuffer rather than the picture path, and
 * how each of n68_bytesrc.h's five promises is kept.
 *
 * STATIC BUDGET: none of its own. Everything lives in the caller's
 * ShotSrc68 (~830 bytes, palette included). No allocation on any path -
 * which is promise (3), and the one this file would be easiest to break.
 *
 * No printf family (numfmt.h only).
 */
#include "shotsrc68.h"

#include "numfmt.h"

#include <Quickdraw.h>

#include <string.h>

/* The screen's CLUT as RGB triples, copied once at open.
 *
 * SNAPSHOTTED RATHER THAN READ PER FILL, for two reasons that are both
 * promises: reading it later would mean dereferencing a CTabHandle inside
 * fill(), and a palette that changed mid-transfer would describe some rows
 * and not others. 256 entries of three bytes is 768 bytes and it is the
 * only thing this source carries. */
static void snapshot_palette(ShotSrc68 *src)
{
    CTabHandle clut;
    long i;

    memset(src->palette, 0, sizeof src->palette);
    if (src->screen.pix == NULL) {
        return;
    }
    clut = (**src->screen.pix).pmTable;
    if (clut == NULL || *clut == NULL) {
        return;
    }
    for (i = 0; i < kN68ShotWirePaletteEntries; ++i) {
        if (i > (long)(**clut).ctSize) {
            break;
        }
        /* The high byte of each 16-bit component. The host draws in 8 bits
         * per channel and the PowerPC guest sends the same narrowing, so
         * two senders agree on what a palette entry means. */
        src->palette[i * 3 + 0] =
            (unsigned char)((**clut).ctTable[i].rgb.red >> 8);
        src->palette[i * 3 + 1] =
            (unsigned char)((**clut).ctTable[i].rgb.green >> 8);
        src->palette[i * 3 + 2] =
            (unsigned char)((**clut).ctTable[i].rgb.blue >> 8);
    }
}

/* One fill: palette bytes while the offset is still inside the palette,
 * then pixels, and never both in one call.
 *
 * NOT BOTH IN ONE CALL is deliberate and costs one extra call per
 * transfer. A short fill is explicitly normal (n68_bytesrc.h: "A SHORT
 * FILL IS NORMAL AND NOT AN ERROR"), and stopping at the boundary keeps
 * the pixel path to one memcpy out of VRAM with one shield around it,
 * rather than a two-source copy that would need the cursor shielded across
 * a region it is not reading. */
static long shot_fill(void *ctx, void *dst, long cap, int *done)
{
    ShotSrc68 *src = (ShotSrc68 *)ctx;
    long row, column, take;

    if (src == NULL || dst == NULL || cap <= 0) {
        return -1;
    }
    if (src->shut) {
        return -1;
    }
    if (src->offset >= src->plan.total) {
        *done = 1;
        return 0;
    }
    if (!n68_shotwire_locate(&src->plan, src->offset, &row, &column)) {
        return -1;
    }

    if (row < 0) {
        /* Still in the palette. */
        take = src->plan.palette_bytes - column;
        if (take > cap) {
            take = cap;
        }
        memcpy(dst, src->palette + column, (size_t)take);
    } else {
        Rect shield;
        Point zero;
        const unsigned char *row_base;

        take = src->plan.row_bytes - column;
        if (take > cap) {
            take = cap;
        }
        /* Straight out of the framebuffer. base + row * rowBytes is the
         * screen's OWN rowBytes (padding included); what is COPIED is the
         * visible part, which is what the plan promised the host. */
        row_base = (const unsigned char *)src->screen.base
                   + row * src->screen.row_bytes;

        /* Shield only the rows this call reads, and only for as long as
         * the copy takes - see shotsrc68.h on why a stream cannot shield
         * the whole transfer. */
        shield = src->screen.bounds;
        shield.top = (short)(src->screen.bounds.top + row);
        shield.bottom = (short)(shield.top + 1);
        zero.h = 0;
        zero.v = 0;
        ShieldCursor(&shield, zero);
        /* Through screen68_vram_read for the 24-bit addressing reason in
         * screen68.h, the same as the staged path. This source has no
         * callers today, and that is exactly why it is fixed here rather
         * than left: the last time this file drifted from the live one,
         * the drift was what a diagnosis chased. */
        screen68_vram_read(src->screen.reach, dst, row_base + column, take);
        ShowCursor();
    }

    src->offset += take;
    if (src->offset >= src->plan.total) {
        *done = 1;
    }
    return take;
}

/* Holds no handle, no fork and no file, so there is nothing to release -
 * but it still marks itself shut, because promise (5) lets the sender stop
 * touching a source after close() and this is what makes a fill after that
 * point an error rather than a read of a screen nobody asked about. */
static void shot_close(void *ctx)
{
    ShotSrc68 *src = (ShotSrc68 *)ctx;

    if (src != NULL) {
        src->shut = 1;
    }
}

static const N68ByteSourceOps kShotSrcOps = { shot_fill, shot_close };

static void say(char *why, long why_cap, const char *text)
{
    long pos = 0;

    if (why == NULL || why_cap <= 0) {
        return;
    }
    (void)now68k_fmt_append_str(why, why_cap - 1, &pos, text);
    why[pos > 0 && pos < why_cap ? pos : 0] = '\0';
}

ShotSrc68Status shotsrc68_open(ShotSrc68 *src, N68ByteSource *out,
                               long *capture_ms, char *why, long why_cap)
{
    unsigned long t0;

    if (src == NULL || out == NULL || why == NULL || why_cap <= 0) {
        return kShotSrc68Geometry;
    }
    memset(src, 0, sizeof *src);
    why[0] = '\0';
    if (capture_ms != NULL) {
        *capture_ms = 0;
    }

    t0 = screen68_micros();
    switch (screen68_info(&src->screen, "capture", why, why_cap)) {
    case kScreen68OK:
        break;
    case kScreen68NoScreen:
        return kShotSrc68NoScreen;
    default:
        /* kScreen68Addressing among them: `why` names it, and sending a
         * frame of main RAM would be worse than refusing. */
        return kShotSrc68Geometry;
    }
    if (!n68_shotwire_plan(src->screen.width, src->screen.height,
                           src->screen.depth, &src->plan)) {
        /* The only geometry the plan refuses that the walk accepts is a
         * depth other than 8, so the sentence can name it rather than
         * saying "geometry" at someone. */
        say(why, why_cap,
            "this lane sends 8-bit screens only and will not convert");
        return kShotSrc68Depth;
    }
    snapshot_palette(src);
    if (capture_ms != NULL) {
        *capture_ms = (long)((screen68_micros() - t0) / 1000UL);
    }

    src->offset = 0;
    src->shut = 0;
    out->ops = &kShotSrcOps;
    out->ctx = src;
    out->total = src->plan.total;
    return kShotSrc68OK;
}
