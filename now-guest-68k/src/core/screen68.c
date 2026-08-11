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
#include <LowMem.h>       /* LMGetMMU32Bit - the CURRENT mode */
#include <MacMemory.h>    /* StripAddress */
#include <OSUtils.h>      /* SwapMMUMode */
#include <Timer.h>

#include <string.h>

/* ---- addressing ----------------------------------------------------------
 *
 * THREE QUANTITIES IN THIS TREE SHARE THE WORD "BIT" AND ARE UNRELATED,
 * which has already confused one reader:
 *
 *   - ADDRESSING MODE - 24-bit or 32-bit, and those are the only two a Mac
 *     has ever had. There is no 16-bit addressing mode; nothing in the
 *     Universal Interfaces names one. That is what this section is about.
 *   - READ WIDTH - vprobe's "Raw 8-bit / 16-bit / 32-bit" rows, which are
 *     move.b / move.w / move.l over the same memory.
 *   - COLOUR DEPTH - the screen's "8-bit", bits per pixel.
 *
 * true32b/false32b are the values SwapMMUMode takes and returns. They are
 * NOT in this toolchain's headers (Multiverse.h declares the call and the
 * trap number and nothing else), so they are spelled here, once, with
 * their documented values from Inside Macintosh: Memory. */
enum {
    kFalse32b = 0,
    kTrue32b  = 1
};

int screen68_mode_is_32bit(void)
{
    /* A plain read of low memory 0x0CB2, not a call - safe to do from
     * inside a 32-bit window, which is exactly what proves the switch
     * took. */
    return LMGetMMU32Bit() != 0;
}

/* Gestalt says the machine is 32-bit capable; the switch itself says it
 * works. Both, because the second is the one that matters and the first is
 * what makes it safe to try: on a Mac that predates 32-bit addressing the
 * _SwapMMUMode trap need not exist, and an unimplemented trap on System
 * 7.1 is a crash rather than a no-op. */
static int can_switch_to_32bit(void)
{
    Screen68Mode m;
    int took;

    if (!screen68_mode_is_32bit()) {
        long attr = 0;

        if (Gestalt(gestaltAddressingModeAttr, &attr) != noErr) {
            return 0;
        }
        if ((attr & (1L << gestalt32BitCapable)) == 0L) {
            return 0;
        }
    }
    /* Proven by doing it, with nothing in between the two swaps. */
    m.saved = kTrue32b;
    SwapMMUMode(&m.saved);
    took = screen68_mode_is_32bit();
    SwapMMUMode(&m.saved);
    return took;
}

Screen68Reach screen68_reach(unsigned long base)
{
    if (can_switch_to_32bit()) {
        return kScreen68ReachSwitch;
    }
    /* Not capable. StripAddress is used as a PREDICATE here and the answer
     * is not rewritten into the base: on a machine that cannot address 32
     * bits, an address the top byte matters to is one this CPU will never
     * see, and 0xFC080000 & 0x00FFFFFF is main RAM rather than a rescue. */
    if ((unsigned long)StripAddress((void *)base) == base) {
        return kScreen68ReachDirect;
    }
    return kScreen68ReachRefused;
}

const char *screen68_reach_reason(Screen68Reach reach)
{
    if (reach == kScreen68ReachRefused) {
        return "this Mac cannot address its own framebuffer (24-bit "
               "addressing, and no 32-bit mode to switch to)";
    }
    return NULL;
}

void screen68_vram_enter(Screen68Reach reach, Screen68Mode *m)
{
    if (m == NULL) {
        return;
    }
    m->saved = kFalse32b;
    m->armed = 0;
    if (reach != kScreen68ReachSwitch) {
        return;
    }
    m->saved = kTrue32b;
    SwapMMUMode(&m->saved);      /* m->saved now holds the mode we left */
    m->armed = 1;
}

void screen68_vram_leave(Screen68Mode *m)
{
    if (m == NULL || !m->armed) {
        return;
    }
    m->armed = 0;
    SwapMMUMode(&m->saved);
}

/* The loops below are written out rather than handed to memcpy/memcmp on
 * purpose. Inside the 32-bit window a cross-segment call would reach the
 * jump table and could fault in the Segment Loader - a Toolbox call, in
 * the one place this file promises there are none. A loop compiled into
 * this function calls nothing.
 *
 * Long-at-a-time when the alignment allows: vprobe measured byte reads of
 * this framebuffer at 2.7x the cost of long reads (484 ms against 179 ms a
 * frame, docs/vram-readout-68k.md), so a byte loop would have made every
 * capture visibly slower to buy nothing. */
void screen68_vram_read(Screen68Reach reach, void *dst, const void *src,
                        long n)
{
    Screen68Mode m;
    unsigned char *d = (unsigned char *)dst;
    const unsigned char *s = (const unsigned char *)src;

    if (dst == NULL || src == NULL || n <= 0) {
        return;
    }
    screen68_vram_enter(reach, &m);
    if ((((unsigned long)d | (unsigned long)s) & 3UL) == 0UL) {
        while (n >= 4) {
            *(unsigned long *)d = *(const unsigned long *)s;
            d += 4;
            s += 4;
            n -= 4;
        }
    }
    while (n-- > 0) {
        *d++ = *s++;
    }
    screen68_vram_leave(&m);
}

int screen68_vram_same(Screen68Reach reach, const void *a, const void *b,
                       long n)
{
    Screen68Mode m;
    const unsigned char *p = (const unsigned char *)a;
    const unsigned char *q = (const unsigned char *)b;
    int same = 1;

    if (a == NULL || b == NULL || n <= 0) {
        return 0;
    }
    screen68_vram_enter(reach, &m);
    while (n-- > 0) {
        if (*p++ != *q++) {
            same = 0;
            break;
        }
    }
    screen68_vram_leave(&m);
    return same;
}

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

    /* Last, because it is about the address the checks above just cleared
     * rather than about the geometry. */
    s->reach = screen68_reach(s->base);
    if (s->reach == kScreen68ReachRefused) {
        pos = 0;
        (void)(now68k_fmt_append_str(why, why_cap - 1, &pos, who)
               && now68k_fmt_append_str(why, why_cap - 1, &pos,
                                        " refused to read: ")
               && now68k_fmt_append_str(why, why_cap - 1, &pos,
                                        screen68_reach_reason(s->reach)));
        if (pos < 0 || pos >= why_cap) {
            pos = 0;
        }
        why[pos] = '\0';
        return kScreen68Addressing;
    }
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
    /* Stripped, which the SCREEN's base deliberately is not (screen68.h).
     * This one is a Memory Manager block: in 24-bit mode its top byte is
     * master-pointer flags, and a caller comparing it against the screen
     * from inside a 32-bit window would follow those flags somewhere else.
     * In 32-bit mode the call is the identity, so this costs nothing. */
    b->base = (Ptr)StripAddress(GetPixBaseAddr(b->pix));
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
