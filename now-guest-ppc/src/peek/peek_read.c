#include "peek_read.h"

#include <MacMemory.h>
#include <Processes.h>

#include <string.h>

#include "axmenu.h"
#include "axprocess.h"
#include "peek.h"
#include "peek_oracle.h"
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

/* The verdict on this partition's anchor, as a read status.

   The matching itself lives in peek_oracle.c, which is Toolbox-free and
   natively tested; this is only the mapping from its five answers to the
   reader's vocabulary. Two of them used to be indistinguishable from
   "nothing captured yet" and now are not.

   No age gate (max_age_ticks 0), which is the rule this reader has
   always followed and is worth restating: window state is always "as of
   the target's last pump" - classic Mac OS has no cross-process live
   window feed, so a snapshot is all any reader can have, axtree
   included. Validation and the A5 match, not a clock, are the safety;
   the application carries the last good read across blips and renders
   the age beside it. Stale is therefore unreachable from here by
   construction, and the caller sees Ok with an old stamp. */
static NowPeekReadStatus anchor_status(const NowPeekTable *table,
                                       unsigned long loc, unsigned long size,
                                       const unsigned char *name,
                                       NowPeekAnchorMatch *match)
{
    switch (now_peek_anchor_match(table, loc, size, name, 0, 0, match)) {
    case kNowPeekAnchorOk:
    case kNowPeekAnchorStale:
        return kNowPeekReadOk;
    case kNowPeekAnchorAmbiguous:
        return kNowPeekReadAmbiguous;
    case kNowPeekAnchorMismatch:
        return kNowPeekReadMismatch;
    case kNowPeekAnchorNotFound:
        break;
    }
    return kNowPeekReadNoAnchor;
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
    Str31 name;
    THz sys;
    NowPeekAnchorMatch match;
    NowPeekReadStatus st;
    unsigned long wl;

    *wl_head = 0;
    *stamp_out = 0;
    table = now_peek_table();
    if (table == NULL || (table->caps & kNowPeekCapAnchors) == 0
        || (table->arm_active & kNowPeekCapAnchors) == 0) {
        return kNowPeekReadNoPlane;
    }
    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    /* The Process Manager fills processName only into a buffer the
       CALLER supplies - a NULL there is silently "do not bother", which
       is what this record used to hand it. The name is the oracle's V3
       discriminator, so it is now asked for. */
    name[0] = 0;
    info.processName = name;
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

    st = anchor_status(table, z->loc, z->size, name, &match);
    if (st != kNowPeekReadOk) {
        return st;                    /* NoAnchor / Ambiguous / Mismatch */
    }
    *stamp_out = match.stamp_ticks;   /* the capture tick, for freshness */
    wl = (unsigned long)match.window_list;
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
        w.address = wl;               /* so a second reader can return */
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
    NowAxContext ctx;
    NowAxMenuList list;
    NowPeekReadStatus st;
    ProcessSerialNumber self;
    Boolean is_self = false;
    unsigned int i;

    if (count == NULL) {
        return kNowPeekReadNoAnchor;
    }
    *count = 0;
    if (psn == NULL || titles == NULL || max <= 0) {
        return kNowPeekReadNoAnchor;
    }
    if (GetCurrentProcess(&self) == noErr) {
        (void)SameProcess(psn, &self, &is_self);
    }
    if (is_self) {
        /* Not a failure and not an empty menu bar: NOW has one, and
           reading it wants the Toolbox rather than this walk. */
        return kNowPeekReadStub;
    }
    /* One bind, one vocabulary: now_ax_bind_process answers in the same
       words this file's other two calls do, so a caller needs no second
       set of names for the same five anchor outcomes. */
    st = now_ax_bind_process(psn, &ctx);
    if (st != kNowPeekReadOk) {
        return st;
    }
    if (now_ax_open_menu_list(&ctx.memory, ctx.menu_list, &list) != kNowAxOk) {
        return kNowPeekReadUnreadable;
    }
    for (i = 0; i < list.count && *count < max; ++i) {
        NowAxMenu menu;
        int n = 0;

        if (now_ax_read_menu(&ctx.memory, &list, i, &menu) != kNowAxOk) {
            /* A bar reported short reads as a complete bar. Refuse the
               whole answer rather than return a prefix of it. */
            *count = 0;
            return kNowPeekReadUnreadable;
        }
        while (menu.title[n] != '\0' && n < 31) {
            titles[*count][n] = menu.title[n];
            ++n;
        }
        titles[*count][n] = '\0';
        ++*count;
    }
    /* Ok with zero titles is a real answer here - see the header. */
    return kNowPeekReadOk;
}
