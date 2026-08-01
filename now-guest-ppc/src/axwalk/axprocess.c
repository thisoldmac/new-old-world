/* Binding one live process to a memory seam. See axprocess.h.

   ON THE TWO ORACLES, since this is where they would have met. Upstream
   ships `ax_oracle_match`, which resolves an A5 sample to a partition;
   NOW ships `now_peek_anchor_match`, which resolves the same thing over
   NOW's own anchor table and answers with the same five verdicts. They
   are the same layer, and importing the second would mean two answers to
   "which process does this pointer belong to" with nothing to break the
   tie. NOW's stays.

   THE ONE THING UPSTREAM'S KNEW THAT OURS DID NOT, since it is now
   closed rather than merely recorded: its sample carries the process's
   NAME (low-memory CurApName, captured in the same context as A5), and
   it compares that name against the Process Manager's before accepting
   a match. That is a genuinely independent discriminator - a recycled
   slot whose A5 and stack base both happen to land inside a live
   partition still has the dead application's name on it. The gap was a
   missing field, not a missing check, so it was closed where it lived:
   anchor format V3 in contract/peek_table.h carries the name, the
   extension captures it in the same context as A5, and the oracle
   checks it. Ours no longer refuses as Ambiguous the case upstream's
   resolves. Still one oracle - NOW's. */

#include "axprocess.h"

#include <MacMemory.h>
#include <Processes.h>

#include <string.h>

#include "peek.h"
#include "peek_validate.h"

/* The seam, on the machine. Every process shares one address space on
   classic Mac OS, so a foreign read IS a memcpy - and that is exactly
   why the validation above it is the whole safety story. Nothing here
   checks anything: by the time this runs, axwalk.c has already proved
   the range lies in one of the two zones. */
static int now_ax_direct_read(void *ctx, unsigned long addr, void *out,
                              size_t len)
{
    (void)ctx;
    BlockMoveData((const void *)addr, out, (Size)len);
    return 1;
}

static unsigned long read_be32(unsigned long addr)
{
    const unsigned char *p = (const unsigned char *)addr;

    return ((unsigned long)p[0] << 24) | ((unsigned long)p[1] << 16)
        | ((unsigned long)p[2] << 8) | (unsigned long)p[3];
}

/* The oracle's five answers in the reader's words. Identical to
   peek_read.c's mapping, deliberately: one plane, one vocabulary. */
static NowPeekReadStatus verdict_status(NowPeekAnchorVerdict v)
{
    switch (v) {
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

NowPeekReadStatus now_ax_bind_process(const ProcessSerialNumber *psn,
                                      NowAxContext *out)
{
    const NowPeekTable *table;
    ProcessInfoRec info;
    Str31 name;
    NowPeekAnchorMatch match;
    NowPeekReadStatus st;
    THz sys;
    unsigned long sys_lo;
    unsigned long sys_hi;

    if (psn == NULL || out == NULL) {
        return kNowPeekReadNoAnchor;
    }
    memset(out, 0, sizeof *out);
    out->verdict = kNowPeekAnchorNotFound;

    table = now_peek_table();
    if (table == NULL || (table->caps & kNowPeekCapAnchors) == 0
        || (table->arm_active & kNowPeekCapAnchors) == 0) {
        return kNowPeekReadNoPlane;
    }

    memset(&info, 0, sizeof info);
    info.processInfoLength = sizeof info;
    /* processName is filled only into a caller-supplied buffer; a NULL
       there means "do not bother". The oracle's V3 name check needs it,
       so it is asked for. */
    name[0] = 0;
    info.processName = name;
    if (GetProcessInformation(psn, &info) != noErr) {
        return kNowPeekReadNoAnchor;
    }
    out->partition_lo = (unsigned long)info.processLocation;
    out->partition_size = (unsigned long)info.processSize;
    if (out->partition_lo == 0 || out->partition_size == 0) {
        return kNowPeekReadNoAnchor;
    }

    /* The system heap's bounds: the zone's own header holds its limit.
       Regions and master pointers live here rather than in the target's
       partition, which is why the walk validates against both. */
    sys = LMGetSysZone();
    sys_lo = (unsigned long)sys;
    sys_hi = (sys != NULL) ? read_be32(sys_lo) : 0;

    /* No age gate (0), per the header: stale is reported, never
       refused. */
    out->verdict = now_peek_anchor_match(table, out->partition_lo,
                                         out->partition_size, name, 0, 0,
                                         &match);
    st = verdict_status(out->verdict);
    if (st != kNowPeekReadOk) {
        return st;
    }
    out->stamp_ticks = match.stamp_ticks;
    out->window_list = (unsigned long)match.window_list;
    out->menu_list = (unsigned long)match.menu_list;

    out->memory.read = now_ax_direct_read;
    out->memory.ctx = NULL;
    out->memory.target_lo = out->partition_lo;
    out->memory.target_hi = out->partition_lo + out->partition_size;
    out->memory.system_lo = sys_lo;
    out->memory.system_hi = sys_hi;

    /* The anchor's own pointers are the first thing the zones are asked
       about. A head that is not readable means the slot is debris even
       though it passed the oracle, and the caller should be told that
       rather than handed a seam that will refuse everything. Both roots
       being absent is legal - a faceless process has neither - so only a
       PRESENT-but-unreadable root is a failure.

       One byte is enough: what is being tested is whether the address
       lies in a readable zone, and the record's real width is checked
       again by the parser that reads it. */
    if ((out->window_list != 0
         && !now_peek_range_in_partition(out->window_list, 1,
                                         out->partition_lo,
                                         out->partition_size)
         && !(sys_hi > sys_lo
              && now_peek_range_in_partition(out->window_list, 1, sys_lo,
                                             sys_hi - sys_lo)))
        || (out->menu_list != 0
            && !now_peek_range_in_partition(out->menu_list, 1,
                                            out->partition_lo,
                                            out->partition_size)
            && !(sys_hi > sys_lo
                 && now_peek_range_in_partition(out->menu_list, 1, sys_lo,
                                                sys_hi - sys_lo)))) {
        return kNowPeekReadUnreadable;
    }
    return kNowPeekReadOk;
}
