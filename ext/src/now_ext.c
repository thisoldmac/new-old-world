/*
 * now_ext.c - the NOW Extension: core (P0) + the anchor plane (P1).
 *
 * A 68K INIT that installs at boot, publishes the shared table in the
 * system heap, registers Gestalt selector 'NWex' to hand out its
 * address, and chains a jGNE filter. The core (P0) stamps a heartbeat
 * every event-loop pass - proof of install, Gestalt, chaining, and
 * liveness. The anchor plane (P1), when the application arms it,
 * additionally records each process's low-memory CurrentA5 / WindowList
 * / MenuList into the shared table while that process's context is
 * current - the only place its per-process Toolbox state is visible
 * (finding observe-process-local-ui). It reads low memory ONLY: no
 * Process Manager call, no allocation, nothing that moves memory. The
 * app correlates A5 to PSN and follows the pointers; foreign-MEMORY
 * reads never happen here (docs/resident-components.md).
 *
 * The table layout is the shared contract compiled by all three sides
 * (contract/peek_table.h); this file is the writer. Foreign-context
 * execution lives here by necessity (the filter runs in every app);
 * foreign-MEMORY reads never will - that stays in the application
 * (docs/resident-components.md).
 *
 * Mechanics mirror tbt's qdpeek/AXPeek, which are metal-proven on this
 * hardware: sysHeap+locked+preload INIT, DetachResource to stay
 * resident, RETRO68_RELOCATE in _start, no Retro68FreeGlobals (the
 * code and its relocated globals live forever). Attend the first metal
 * boot: a fault here executes inside every app that pumps events.
 */

#include <Gestalt.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <OSUtils.h>
#include <Resources.h>
#include <Retro68Runtime.h>
#include <Traps.h>

#include "peek_table.h"

/* Resident state. The relocated flat blob is at a fixed system-heap
   address (sysHeap+locked+detached), so these absolute pointers are
   valid from any later context - which is why we never call
   Retro68FreeGlobals(). */
static NowPeekTable *gNowExtTable = NULL;

/* Chained by the asm shim after our applier runs. Referenced from
   assembly, so it is a plain module global with external linkage. */
GetNextEventFilterUPP gNowExtOldGNEFilter = NULL;

/* The assembly shim (now_ext_gne.S), tail-chained onto jGNE. */
extern void now_ext_gne_filter(void);

/* Fast-path cache: consecutive GetNextEvent calls are usually the same
   front app, so an A5 match skips the slot scan. Lives in the resident
   relocated BSS (fixed system-heap address), valid from any context. */
static NowPeekU32 gLastA5;
static short gLastSlot = -1;
static NowPeekU16 gAnchorCount;

/* Which slot holds this A5's anchor: an exact match, else an empty slot
   (a5 == 0), else the stalest (oldest stamp) to recycle. O(32), and the
   A5 fast path above skips it on the common pass. */
static short find_anchor_slot(NowPeekU32 a5)
{
    short i;
    short empty = -1;
    short stalest = 0;
    NowPeekU32 oldest = 0xFFFFFFFFUL;

    for (i = 0; i < kNowPeekMaxAnchors; ++i) {
        NowPeekAnchorSlot *slot = &gNowExtTable->anchors[i];

        if (slot->a5 == a5) {
            return i;
        }
        if (slot->a5 == 0 && empty < 0) {
            empty = i;
        }
        if (slot->stamp_ticks < oldest) {
            oldest = slot->stamp_ticks;
            stalest = i;
        }
    }
    return empty >= 0 ? empty : stalest;
}

/* Record the current context's anchors. Stamp is written LAST as the
   commit, and zeroed first as an invalidation, so a reader that
   double-samples the stamp can tell a torn cross-update read from a
   stable one (peek_table.h documents the discipline). A5-aligned
   32-bit stores are atomic on the 68020+/PPC this ships to. */
static void capture_anchor(void)
{
    NowPeekU32 a5 = (NowPeekU32)LMGetCurrentA5();
    NowPeekAnchorSlot *slot;
    short idx;

    if (a5 == 0) {
        return;                       /* no valid A5 world to anchor */
    }
    if (a5 == gLastA5 && gLastSlot >= 0) {
        idx = gLastSlot;
    } else {
        idx = find_anchor_slot(a5);
        gLastA5 = a5;
        gLastSlot = idx;
    }
    slot = &gNowExtTable->anchors[idx];
    if (slot->a5 == 0 && gAnchorCount < kNowPeekMaxAnchors) {
        gNowExtTable->anchor_count = ++gAnchorCount;
    }
    slot->stamp_ticks = 0;                          /* invalidate */
    slot->a5 = a5;
    slot->window_list = (NowPeekU32)LMGetWindowList();
    slot->menu_list = (NowPeekU32)LMGetMenuList();
    slot->psn_high = 0;               /* the extension never fills PSN; */
    slot->psn_low = 0;                /* the app correlates A5 to PSN */
    slot->stamp_ticks = (NowPeekU32)LMGetTicks();   /* commit last */
}

/* Called from the shim on every GetNextEvent/WaitNextEvent, in whatever
   process is pumping. The heartbeat (P0) is always stamped - it is how
   a reader tells "running" from "wedged". The anchor capture (P1) runs
   only when the application has armed it; the arm handshake is the
   plane's contract (docs/resident-components.md). Both are a handful of
   low-memory reads and stores - allocate nothing, call nothing that
   moves memory. */
void now_ext_gne_apply(void)
{
    NowPeekTable *table = gNowExtTable;

    if (table == NULL) {
        return;
    }
    table->heartbeat = (NowPeekU32)LMGetTicks();
    if (table->arm_request & kNowPeekTableCapAnchors) {
        capture_anchor();
        table->arm_active |= kNowPeekTableCapAnchors;
    } else if (table->arm_active & kNowPeekTableCapAnchors) {
        table->arm_active &= ~(NowPeekU32)kNowPeekTableCapAnchors;
    }
}

/* Gestalt hands any caller the table's address. Uses a real UPP
   (NewSelectorFunctionUPP): Gestalt can be reached from native/PPC
   callers through Mixed Mode, so this one genuinely needs a routine
   descriptor - unlike the 68K jGNE filter, which the Event Manager
   calls as bare 68K code. */
static pascal OSErr now_ext_gestalt(OSType selector, long *response)
{
    (void)selector;
    *response = (long)gNowExtTable;
    return noErr;
}

void _start(void)
{
    Handle self;
    SelectorFunctionUPP gestalt_upp;
    NowPeekTable *table;
    OSErr err;

    RETRO68_RELOCATE();
    Retro68CallConstructors();

    /* Keep the code resident after the extension's resource file
       closes: detach the locked INIT so DisposeWindow-of-the-world at
       boot's end does not take it. */
    self = Get1Resource('INIT', 128);
    if (self == NULL) {
        return;
    }
    DetachResource(self);

    table = (NowPeekTable *)NewPtrSysClear((Size)sizeof(NowPeekTable));
    if (table == NULL) {
        return;                       /* no heap: degrade to absent */
    }
    table->ext_major = kNowPeekExtMajor;
    table->ext_minor = 0;
    /* The anchor region is real, backed memory now (P1), so length
       covers the whole table; the app still trusts an individual slot
       only when the plane is armed and the slot's stamp is fresh. */
    table->length = (NowPeekU32)sizeof(NowPeekTable);
    /* P1 is AVAILABLE but dark: advertised in caps, captured nothing
       until the app writes arm_request. */
    table->caps = kNowPeekTableCapAnchors;
    table->boot_ticks = (NowPeekU32)LMGetTicks();
    table->heartbeat = table->boot_ticks;
    table->arm_request = 0;
    table->arm_active = 0;
    table->anchor_format = kNowPeekAnchorFormatV1;
    table->anchor_count = 0;
    /* Magic last: a reader that somehow sees the address early finds it
       only once the table is fully formed. */
    table->magic = (NowPeekU32)kNowPeekTableMagic;
    gNowExtTable = table;

    /* Publish before hooking: if Gestalt registration fails there is no
       point installing a filter no one can discover, and we unwind the
       heap block cleanly. */
    gestalt_upp = NewSelectorFunctionUPP(now_ext_gestalt);
    err = NewGestalt((OSType)kNowPeekGestaltSelector, gestalt_upp);
    if (err != noErr) {
        if (gestalt_upp != NULL) {
            DisposeSelectorFunctionUPP(gestalt_upp);
        }
        DisposePtr((Ptr)table);
        gNowExtTable = NULL;
        return;
    }

    /* Chain the jGNE filter last (install callbacks last, per the INIT
       failure-atomicity rule): save the incumbent for the shim to
       tail-call, then point the low-memory vector at our 68K shim.
       Cast is correct here - on pure 68K a filter UPP is a bare code
       pointer, and the shim owns the non-C ABI. */
    gNowExtOldGNEFilter = LMGetGNEFilter();
    LMSetGNEFilter((GetNextEventFilterUPP)now_ext_gne_filter);

    /* Resident forever: no Retro68FreeGlobals(), no unwind past here. */
}
