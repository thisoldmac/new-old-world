/* Read NOW's single resident extension, in AXPeek's shape.
 * See nowpeek.h for why this exists at all.
 */

#include "nowpeek.h"

#include <Gestalt.h>
#include <MacMemory.h>
#include <MacTypes.h>
#include <string.h>

#include "peek_table.h"

/* The Gestalt answer is an ADDRESS, and a wrong one dereferenced on a
   machine with no memory protection is not an error, it is a crash. So
   the same range check AXPeek's reader used: 4-aligned, and the whole
   struct inside the system heap we were handed bounds for. */
static int table_range_valid(unsigned long addr, unsigned long lo,
                             unsigned long hi, unsigned long size)
{
    if (addr == 0 || (addr & 3UL) != 0) {
        return 0;
    }
    if (addr < lo || addr >= hi) {
        return 0;
    }
    if (size > (unsigned long)(hi - addr)) {
        return 0;
    }
    return 1;
}

static NowPeekTable *locate(unsigned long lo, unsigned long hi)
{
    long response = 0;

    if (Gestalt(kNowPeekGestaltSelector, &response) != noErr
        || response <= 0) {
        return NULL;
    }
    /* Bound the PRELUDE first. The full table is larger than the part we
       are about to read, and demanding room for all of it before we have
       even checked the magic would refuse a shorter, older, perfectly
       readable resident. */
    if (!table_range_valid((unsigned long)response, lo, hi,
                           (unsigned long)sizeof(NowPeekTable))) {
        return NULL;
    }
    return (NowPeekTable *)(unsigned long)response;
}

void now_peek_arm(void)
{
    /* Bounds come from the caller for the snapshot; for the arm we have
       none, so this deliberately does nothing on its own and the arming
       is folded into now_peek_snapshot, which HAS them. Kept as a named
       entry point because callers reasonably look for one. */
}

int now_peek_snapshot(unsigned long system_lo, unsigned long system_hi,
                      AXShared *out)
{
    NowPeekTable *table;
    unsigned long need;
    uint32_t      count;
    uint32_t      i;
    uint32_t      kept = 0;

    if (out == NULL) {
        return AX_ORACLE_INVALID;
    }
    memset(out, 0, sizeof(*out));

    table = locate(system_lo, system_hi);
    if (table == NULL) {
        return AX_ORACLE_NOT_FOUND;
    }
    if (table->magic != (NowPeekU32)kNowPeekTableMagic
        || table->ext_major != kNowPeekExtMajor) {
        return AX_ORACLE_INVALID;
    }
    /* Length gates the read, per the table's own prefs-record rule: a
       resident that predates the anchor region reports a shorter length
       and must be refused rather than read past. */
    need = (unsigned long)offsetof(NowPeekTable, anchors);
    if ((unsigned long)table->length < need) {
        return AX_ORACLE_INVALID;
    }
    if ((table->caps & (NowPeekU32)kNowPeekTableCapAnchors) == 0) {
        return AX_ORACLE_INVALID;
    }

    /* ASK FOR CAPTURES, EVERY TIME. NOW's anchor plane is armed rather
       than always-on - that is its deliberate difference from AXPeek,
       and it means a reader that never asks sees an empty table forever.
       This is the one write this file makes, into the one word the
       application half of the contract owns. */
    table->arm_request |= (NowPeekU32)kNowPeekTableCapAnchors;

    count = table->anchor_count;
    if (count > (uint32_t)kNowPeekMaxAnchors) {
        count = (uint32_t)kNowPeekMaxAnchors;
    }
    if (count > (uint32_t)AX_SAMPLE_MAX) {
        count = (uint32_t)AX_SAMPLE_MAX;
    }

    for (i = 0; i < count; i++) {
        volatile NowPeekAnchorSlot *slot = &table->anchors[i];
        AXContextSample            *dst = &out->samples[kept];
        int                         attempt;

        /* PER-SLOT seqlock, which is the other difference from AXPeek.
           The extension zeroes stamp_ticks, writes the slot, then
           commits the stamp last - so a stable non-zero stamp either
           side of the copy means the slot did not move under us. A torn
           or empty slot is SKIPPED, not fatal: one process rewriting its
           anchor must not cost us the other thirty-one. */
        for (attempt = 0; attempt < 4; attempt++) {
            uint32_t before = slot->stamp_ticks;
            uint32_t after;

            if (before == 0) {
                break;                  /* never captured; not a failure */
            }
            dst->currentA5 = slot->a5;
            dst->stackBase = slot->stack_base;
            dst->windowList = slot->window_list;
            dst->menuList = slot->menu_list;
            dst->ticks = before;
            memcpy(dst->appName, (const void *)slot->cur_ap_name,
                   sizeof dst->appName);
            after = slot->stamp_ticks;
            if (after == before) {
                kept++;
                break;
            }
        }
    }

    /* Wear AXPeek's identity so nothing downstream has to know. The
       oracle that consumes this - axoracle.c :: match - was never
       AXPeek-specific; it elects a slot by partition containment and
       refutes on the name, which is as true of these anchors as of
       those. */
    out->magic = AX_MAGIC;
    out->version = AX_VERSION;
    out->seq = 0;
    out->ticks = table->heartbeat;
    /* AXShared's `calls` meant "committed samples; 0 => dead". NOW keeps
       no such counter, and inventing one from the heartbeat would be a
       number that looks measured and is not. The heartbeat IS the
       liveness fact and it is in `ticks` above. */
    out->calls = 0;
    out->lastTrap = 0;
    out->lastErr = 0;
    out->sampleCount = kept;
    out->nextSlot = 0;

    /* Armed but nothing captured yet is NOT invalid - it is the state of
       a machine one event-loop pass after the first arm, and the caller's
       own "no slot matched" path says it better than a hard error would. */
    return AX_ORACLE_OK;
}
