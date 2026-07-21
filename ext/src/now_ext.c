/*
 * now_ext.c - the NOW Extension, plane P0 (M0: core residence).
 *
 * A 68K INIT that installs at boot, publishes the shared table in the
 * system heap, registers Gestalt selector 'NWex' to hand out its
 * address, and chains a jGNE filter that stamps a heartbeat every
 * event-loop pass. That is the whole of M0: it proves install,
 * Gestalt, filter chaining, and liveness, and it flips the
 * application's peek.h status from "not installed" to "active". No
 * anchors, no foreign reads, no arming - those are P1 and later, and
 * they hang off this same core.
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

/* Called from the shim on every GetNextEvent/WaitNextEvent, in whatever
   process is pumping. Must be nearly free and allocate nothing: one
   TickCount read and one 32-bit store to the fixed table. This is the
   liveness signal a reader uses to tell "running" from "wedged"; P1's
   per-context anchor capture will extend it. */
void now_ext_gne_apply(void)
{
    if (gNowExtTable != NULL) {
        gNowExtTable->heartbeat = (NowPeekU32)LMGetTicks();
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
    /* M0 publishes the prelude only; the anchor slots are allocated
       (so P1 arms in place at the same Gestalt address) but not yet
       backed, so length stops before them and a reader refuses anchor
       reads. This is exactly what peek_table_test pins. */
    table->length = (NowPeekU32)offsetof(NowPeekTable, anchors);
    table->caps = 0;                  /* no planes armed at M0 */
    table->boot_ticks = (NowPeekU32)LMGetTicks();
    table->heartbeat = table->boot_ticks;
    table->arm_request = 0;
    table->arm_active = 0;
    table->anchor_format = kNowPeekAnchorFormatNone;
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
