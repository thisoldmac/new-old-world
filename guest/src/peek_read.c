#include "peek_read.h"

#include <Processes.h>

#include <string.h>

#include "peek.h"
#include "peek_validate.h"

/* We read another process's raw in-memory structures by offset, NOT
   through the Toolbox types. Two reasons: under Carbon those types are
   opaque, and their accessors would call the Window Manager on OUR
   behalf, not read foreign bytes; and the classic layout is 2-byte
   packed (68K), so a PPC-compiled struct would pad `strucRgn` from
   offset 114 to 116 and read the wrong word. Explicit offsets with
   byte reads are alignment- and endian-safe (68K and PPC are both
   big-endian, and the fields sit at these fixed classic offsets across
   8.6-9.2.2). */
enum {
    /* WindowRecord: a 108-byte GrafPort/CGrafPort, then windowKind(2),
       visible(1), hilited(1), goAwayFlag(1), spareFlag(1), then
       strucRgn. Total record is 156 bytes. */
    kWindowRecordSize = 156,
    kOffStrucRgn = 114,           /* RgnHandle within the WindowRecord */
    /* Region: rgnSize(2), then rgnBBox. */
    kOffRgnBBox = 2,
    kRegionHeader = kOffRgnBBox + 8,   /* enough to hold the bbox */

    kFreshTicks = 120             /* ~2 s; the front app stamps far fresher */
};

/* Byte reads at a validated address - always aligned, explicitly
   big-endian, so no unaligned-access or struct-padding surprises. */
static unsigned long read_be32(unsigned long addr)
{
    const unsigned char *p = (const unsigned char *)addr;

    return ((unsigned long)p[0] << 24) | ((unsigned long)p[1] << 16)
        | ((unsigned long)p[2] << 8) | (unsigned long)p[3];
}

static short read_be16(unsigned long addr)
{
    const unsigned char *p = (const unsigned char *)addr;

    return (short)(((unsigned)p[0] << 8) | (unsigned)p[1]);
}

/* The front app's front-window pointer from a fresh, in-partition
   anchor, or 0. Double-samples the stamp so a torn cross-update read is
   skipped rather than trusted. */
static unsigned long front_window_pointer(const NowPeekTable *table,
                                          unsigned long loc,
                                          unsigned long size,
                                          unsigned long now)
{
    int i;

    for (i = 0; i < (int)kNowPeekMaxAnchors; ++i) {
        const NowPeekAnchorSlot *slot = &table->anchors[i];
        NowPeekU32 s1 = slot->stamp_ticks;
        NowPeekU32 a5;
        NowPeekU32 wl;
        NowPeekU32 s2;

        if (s1 == 0) {
            continue;                 /* empty or mid-update */
        }
        a5 = slot->a5;
        wl = slot->window_list;
        s2 = slot->stamp_ticks;
        if (s1 != s2) {
            continue;                 /* torn: updated while reading */
        }
        if ((NowPeekU32)(now - s1) > (NowPeekU32)kFreshTicks) {
            continue;                 /* stale: its app is not pumping */
        }
        /* The anchor is this process's only if its A5 lives in the
           process's partition - the containment IS the PSN<->A5
           correlation, and it fails closed. */
        if (!now_peek_range_in_partition(a5, 4, loc, size)) {
            continue;
        }
        return wl;
    }
    return 0;
}

Boolean now_peek_front_window(NowPeekBounds *out)
{
    const NowPeekTable *table;
    ProcessSerialNumber psn;
    ProcessInfoRec info;
    unsigned long loc;
    unsigned long size;
    unsigned long wl;
    unsigned long struc;
    unsigned long region;
    short top;
    short left;
    short bottom;
    short right;

    memset(out, 0, sizeof *out);

    table = now_peek_table();
    if (table == NULL || (table->caps & kNowPeekCapAnchors) == 0
        || (table->arm_active & kNowPeekCapAnchors) == 0) {
        return false;                 /* absent, no plane, or not armed */
    }

    if (GetFrontProcess(&psn) != noErr) {
        return false;
    }
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    if (GetProcessInformation(&psn, &info) != noErr) {
        return false;
    }
    loc = (unsigned long)info.processLocation;
    size = (unsigned long)info.processSize;
    if (loc == 0 || size == 0) {
        return false;
    }

    wl = front_window_pointer(table, loc, size, (unsigned long)TickCount());
    if (wl == 0) {
        return false;                 /* no fresh anchor for the front app */
    }

    /* Every dereference below is gated on the partition first; a value
       that fails a check means we misread, and we fail closed. */
    if (!now_peek_range_in_partition(wl, kWindowRecordSize, loc, size)) {
        return false;
    }
    struc = read_be32(wl + kOffStrucRgn);          /* the RgnHandle */
    if (!now_peek_range_in_partition(struc, 4, loc, size)) {
        return false;
    }
    region = read_be32(struc);                     /* master-ptr deref */
    if (!now_peek_range_in_partition(region, kRegionHeader, loc, size)) {
        return false;
    }
    top = read_be16(region + kOffRgnBBox);
    left = read_be16(region + kOffRgnBBox + 2);
    bottom = read_be16(region + kOffRgnBBox + 4);
    right = read_be16(region + kOffRgnBBox + 6);
    if (!now_peek_rect_sane(top, left, bottom, right)) {
        return false;
    }

    out->top = top;
    out->left = left;
    out->bottom = bottom;
    out->right = right;
    out->valid = true;
    return true;
}
