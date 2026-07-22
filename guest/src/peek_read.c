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
    kOffTitleHandle = 134,        /* StringHandle (the window title) */
    kOffNextWindow = 144,         /* WindowPeek to the next window */
    kOffRgnBBox = 2,              /* Rect after the 2-byte rgnSize */
    kRegionHeader = kOffRgnBBox + 8,

    kWindowChainCap = 64          /* bound the walk against a cyclic chain */
};

/* The zones a foreign window structure may legally live in: the
   process's own partition, or the system heap (some regions and master
   pointers live there - validating only the partition read
   "unreadable" for every process but oneself; tbt's axtree needed the
   same widening). */
typedef struct {
    unsigned long loc;
    unsigned long size;
    unsigned long sys_lo;
    unsigned long sys_hi;
} ReadableZones;

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

/* The anchor's window-list head for the process whose partition is
   [loc,size): the slot whose A5 lies in that partition (the containment
   IS the PSN<->A5 correlation, and it is what makes the slot provably
   this process's - not time). Double-samples the stamp against a torn
   cross-update read. There is no age gate: window state is always "as
   of the target's last pump" (classic Mac OS has no cross-process live
   window feed, so a snapshot is all any reader can have - axtree
   included), and validation plus the A5 match, not a clock, are the
   safety; the application carries the last good read across blips.
   *found tells "no anchor at all" from "anchor found, WindowList 0". */
static unsigned long process_window_list(const NowPeekTable *table,
                                         unsigned long loc,
                                         unsigned long size, int *found,
                                         NowPeekU32 *stamp_out)
{
    int i;

    *found = 0;
    *stamp_out = 0;
    for (i = 0; i < (int)kNowPeekMaxAnchors; ++i) {
        const NowPeekAnchorSlot *slot = &table->anchors[i];
        NowPeekU32 s1 = slot->stamp_ticks;
        NowPeekU32 a5;
        NowPeekU32 wl;
        NowPeekU32 s2;

        if (s1 == 0) {
            continue;                 /* never captured, or mid-update */
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
        *stamp_out = s1;              /* the capture tick, for freshness */
        return wl;
    }
    return 0;
}

/* Resolve a process to its readable zones and window-list head. Returns
   a status; on kNowPeekReadOk, *wl_head is the (validated non-zero)
   first window, and NoWindows is returned when the anchor is fine but
   the list is empty. */
static NowPeekReadStatus resolve(const ProcessSerialNumber *psn,
                                 ReadableZones *z, unsigned long *wl_head,
                                 NowPeekU32 *stamp_out)
{
    const NowPeekTable *table;
    ProcessInfoRec info;
    THz sys;
    unsigned long wl;
    int found;

    *wl_head = 0;
    *stamp_out = 0;
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
    z->loc = (unsigned long)info.processLocation;
    z->size = (unsigned long)info.processSize;
    if (z->loc == 0 || z->size == 0) {
        return kNowPeekReadNoAnchor;
    }
    sys = LMGetSysZone();
    z->sys_lo = (unsigned long)sys;
    z->sys_hi = (sys != NULL) ? read_be32(z->sys_lo) : 0;

    wl = process_window_list(table, z->loc, z->size, &found, stamp_out);
    if (!found) {
        return kNowPeekReadNoAnchor;
    }
    if (wl == 0) {
        return kNowPeekReadNoWindows;
    }
    if (!in_readable(z, wl, kWindowRecordSize)) {
        return kNowPeekReadUnreadable;
    }
    *wl_head = wl;
    return kNowPeekReadOk;
}

/* A window's global bounds from its strucRgn->rgnBBox. Returns 0 on any
   validation failure. */
static int read_bounds(const ReadableZones *z, unsigned long wl,
                       NowPeekWindow *out)
{
    unsigned long struc;
    unsigned long region;

    struc = read_be32(wl + kOffStrucRgn);
    if (!in_readable(z, struc, 4)) {
        return 0;
    }
    region = read_be32(struc);
    if (!in_readable(z, region, kRegionHeader)) {
        return 0;
    }
    out->top = read_be16(region + kOffRgnBBox);
    out->left = read_be16(region + kOffRgnBBox + 2);
    out->bottom = read_be16(region + kOffRgnBBox + 4);
    out->right = read_be16(region + kOffRgnBBox + 6);
    return now_peek_rect_sane(out->top, out->left, out->bottom,
                              out->right);
}

/* A window's title (a Pascal string behind titleHandle). Leaves the
   title empty on any validation failure - a missing title is not a
   read failure, just a nameless window. */
static void read_title(const ReadableZones *z, unsigned long wl,
                       char *out, long cap)
{
    unsigned long th;
    unsigned long sp;
    unsigned len;
    unsigned i;

    out[0] = '\0';
    th = read_be32(wl + kOffTitleHandle);
    if (!in_readable(z, th, 4)) {
        return;
    }
    sp = read_be32(th);               /* master-ptr deref */
    if (!in_readable(z, sp, 1)) {
        return;
    }
    len = *(const unsigned char *)sp;
    if (len > (unsigned)(cap - 1)) {
        len = (unsigned)(cap - 1);
    }
    if (len == 0 || !in_readable(z, sp, 1 + len)) {
        return;
    }
    for (i = 0; i < len; ++i) {
        out[i] = *(const char *)(sp + 1 + i);
    }
    out[len] = '\0';
}

/* Our OWN windows, read through the Window Manager rather than the anchor
   plane's foreign-memory walk. NOW is a Carbon app: its window records do
   not sit at the classic 68K WindowRecord offsets the foreign path reads,
   so reading self that way returns "unreadable". For self there is no
   reason to go foreign at all - the Toolbox will hand us our own bounds
   and titles directly, and they are always live. */
static NowPeekReadStatus read_own_windows(NowPeekWindowList *out)
{
    WindowRef win = FrontWindow();
    int hops;

    out->stamp_ticks = (NowPeekU32)TickCount();   /* own state is live */
    for (hops = 0; win != NULL && hops < kWindowChainCap; ++hops) {
        Rect r;

        GetWindowBounds(win, kWindowStructureRgn, &r);
        if (now_peek_rect_sane(r.top, r.left, r.bottom, r.right)) {
            if (out->count < kNowPeekMaxWindows) {
                NowPeekWindow *w = &out->windows[out->count];
                Str255 title;
                short len;

                w->top = r.top;
                w->left = r.left;
                w->bottom = r.bottom;
                w->right = r.right;
                GetWTitle(win, title);
                len = title[0];
                if (len > kNowPeekTitleMax - 1) {
                    len = kNowPeekTitleMax - 1;
                }
                if (len > 0) {
                    memcpy(w->title, title + 1, (size_t)len);
                }
                w->title[len] = '\0';
                ++out->count;
            } else {
                out->more = true;
            }
        }
        win = GetNextWindow(win);
    }
    return out->count > 0 ? kNowPeekReadOk : kNowPeekReadNoWindows;
}

NowPeekReadStatus now_peek_windows_for_psn(const ProcessSerialNumber *psn,
                                           NowPeekWindowList *out)
{
    ReadableZones z;
    unsigned long wl;
    NowPeekU32 stamp = 0;
    NowPeekReadStatus st;
    int hops;
    ProcessSerialNumber self;
    Boolean is_self = false;

    memset(out, 0, sizeof *out);
    if (GetCurrentProcess(&self) == noErr) {
        (void)SameProcess(psn, &self, &is_self);
    }
    if (is_self) {
        return read_own_windows(out);
    }
    st = resolve(psn, &z, &wl, &stamp);
    if (st != kNowPeekReadOk) {
        return st;
    }
    out->stamp_ticks = stamp;
    for (hops = 0; wl != 0 && hops < kWindowChainCap; ++hops) {
        NowPeekWindow w;

        if (!in_readable(&z, wl, kWindowRecordSize)) {
            break;                    /* chain left the readable zones */
        }
        memset(&w, 0, sizeof w);
        if (read_bounds(&z, wl, &w)) {
            read_title(&z, wl, w.title, sizeof w.title);
            if (out->count < kNowPeekMaxWindows) {
                out->windows[out->count++] = w;
            } else {
                out->more = true;
            }
        }
        wl = read_be32(wl + kOffNextWindow);
    }
    /* The head validated in resolve(), so a zero count here means the
       head's bounds were insane - unreadable, not empty. */
    return out->count > 0 ? kNowPeekReadOk : kNowPeekReadUnreadable;
}

NowPeekReadStatus now_peek_window_count(const ProcessSerialNumber *psn,
                                        short *count)
{
    ReadableZones z;
    unsigned long wl;
    NowPeekU32 stamp = 0;
    NowPeekReadStatus st;
    int hops;
    short n = 0;
    ProcessSerialNumber self;
    Boolean is_self = false;

    *count = 0;
    if (GetCurrentProcess(&self) == noErr) {
        (void)SameProcess(psn, &self, &is_self);
    }
    if (is_self) {
        NowPeekWindowList w;

        st = read_own_windows(&w);
        *count = w.count;
        return st;
    }
    st = resolve(psn, &z, &wl, &stamp);   /* stamp unused for the badge */
    if (st != kNowPeekReadOk) {
        return st;                    /* NoWindows/NoAnchor/etc as-is */
    }
    for (hops = 0; wl != 0 && hops < kWindowChainCap; ++hops) {
        if (!in_readable(&z, wl, kWindowRecordSize)) {
            break;
        }
        ++n;
        wl = read_be32(wl + kOffNextWindow);
    }
    *count = n;
    return n > 0 ? kNowPeekReadOk : kNowPeekReadUnreadable;
}

NowPeekReadStatus now_peek_menu_titles(const ProcessSerialNumber *psn,
                                       char titles[][32], int max,
                                       int *count)
{
    (void)psn;
    (void)titles;
    (void)max;
    /* Stub: the anchor captures menu_list, but this walk is a later
       pass. The wiring is here so adding it stays app-only. */
    *count = 0;
    return kNowPeekReadStub;
}
