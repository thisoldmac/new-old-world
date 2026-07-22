#include "peek_read.h"

#include <MacMemory.h>
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
    kWindowRecordSize = 156,      /* classic WindowRecord */
    kOffStrucRgn = 114,           /* RgnHandle within the WindowRecord */
    kOffRgnBBox = 2,              /* Rect after the 2-byte rgnSize */
    kRegionHeader = kOffRgnBBox + 8
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

/* The two zones a foreign window structure may legally live in: the
   process's own partition, or the system heap. A window record is
   usually in the app's heap, but some regions and master pointers are
   in the system heap - validating only the partition read "unreadable"
   for every process but oneself (tbt's axtree needed the same widening:
   partition PLUS validated SysZone). */
typedef struct {
    unsigned long loc;
    unsigned long size;
    unsigned long sys_lo;
    unsigned long sys_hi;
} ReadableZones;

static int in_readable(const ReadableZones *z, unsigned long addr,
                       unsigned long len)
{
    if (now_peek_range_in_partition(addr, len, z->loc, z->size)) {
        return 1;
    }
    if (z->sys_hi > z->sys_lo
        && now_peek_range_in_partition(addr, len, z->sys_lo,
                                       z->sys_hi - z->sys_lo)) {
        return 1;
    }
    return 0;
}

/* The window-list head for the process whose partition is [loc,size):
   the anchor slot whose A5 lies in that partition (the containment IS
   the PSN<->A5 correlation). Double-samples the stamp so a torn
   cross-update read is skipped. `*found` distinguishes "no anchor for
   this process" from "anchor found, but the process has no windows"
   (WindowList 0). No age gate: a live process's slot is what matters,
   and the A5-in-partition check already rejects a recycled slot. */
static unsigned long process_window_list(const NowPeekTable *table,
                                         unsigned long loc,
                                         unsigned long size, int *found)
{
    int i;

    *found = 0;
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
        if (!now_peek_range_in_partition(a5, 4, loc, size)) {
            continue;                 /* not this process's A5 */
        }
        *found = 1;
        return wl;
    }
    return 0;
}

NowPeekReadStatus now_peek_window_for_psn(const ProcessSerialNumber *psn,
                                          NowPeekBounds *out)
{
    const NowPeekTable *table;
    ProcessInfoRec info;
    ReadableZones z;
    THz sys;
    unsigned long wl;
    unsigned long struc;
    unsigned long region;
    int found;
    short top;
    short left;
    short bottom;
    short right;

    memset(out, 0, sizeof *out);

    table = now_peek_table();
    if (table == NULL || (table->caps & kNowPeekCapAnchors) == 0
        || (table->arm_active & kNowPeekCapAnchors) == 0) {
        return kNowPeekReadNoPlane;
    }

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    if (GetProcessInformation(psn, &info) != noErr) {
        return kNowPeekReadNoAnchor;
    }
    z.loc = (unsigned long)info.processLocation;
    z.size = (unsigned long)info.processSize;
    if (z.loc == 0 || z.size == 0) {
        return kNowPeekReadNoAnchor;
    }
    /* System-heap bounds: [zone header, bkLim). bkLim is the zone's
       first field, so it reads at the header address itself. */
    sys = LMGetSysZone();
    z.sys_lo = (unsigned long)sys;
    z.sys_hi = (sys != NULL) ? read_be32(z.sys_lo) : 0;

    wl = process_window_list(table, z.loc, z.size, &found);
    if (!found) {
        return kNowPeekReadNoAnchor;
    }
    if (wl == 0) {
        return kNowPeekReadNoWindows; /* anchor is fine; no open windows */
    }

    /* Every dereference is gated on a readable zone first; a value that
       fails means we misread, and we fail closed as "unreadable". */
    if (!in_readable(&z, wl, kWindowRecordSize)) {
        return kNowPeekReadUnreadable;
    }
    struc = read_be32(wl + kOffStrucRgn);          /* the RgnHandle */
    if (!in_readable(&z, struc, 4)) {
        return kNowPeekReadUnreadable;
    }
    region = read_be32(struc);                     /* master-ptr deref */
    if (!in_readable(&z, region, kRegionHeader)) {
        return kNowPeekReadUnreadable;
    }
    top = read_be16(region + kOffRgnBBox);
    left = read_be16(region + kOffRgnBBox + 2);
    bottom = read_be16(region + kOffRgnBBox + 4);
    right = read_be16(region + kOffRgnBBox + 6);
    if (!now_peek_rect_sane(top, left, bottom, right)) {
        return kNowPeekReadUnreadable;
    }

    out->top = top;
    out->left = left;
    out->bottom = bottom;
    out->right = right;
    out->valid = true;
    return kNowPeekReadOk;
}
