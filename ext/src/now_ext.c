/*
 * now_ext.c - the NOW Extension: core (P0) + the anchor plane (P1).
 *
 * A 68K INIT that installs at boot, publishes the shared table in the
 * system heap, registers Gestalt selector 'NWex' to hand out its
 * address, and chains a jGNE filter. The core (P0) stamps a heartbeat
 * every event-loop pass - proof of install, Gestalt, chaining, and
 * liveness. The anchor plane (P1), when the application arms it,
 * additionally records each process's low-memory CurrentA5 / WindowList
 * / MenuList / CurStackBase / CurApName into the shared table while
 * that process's context is current - the only place its per-process
 * Toolbox state is visible (finding observe-process-local-ui). It
 * reads low memory ONLY: no
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

/* Low memory as bytes, through a volatile the optimiser cannot fold.

   LMGetCurApName is a literal address (0x0910), and gcc's array-bounds
   pass reads a constant pointer as an object of KNOWN size - a small
   integer address looks to it like "likely at address zero", so
   indexing it is diagnosed as out of bounds and -Werror stops the
   build. The bounds are real, they are simply not visible from C: this
   is the system's own storage, not an array the compiler declared.
   Routing the address through a volatile is the narrowest way to say
   so, and it is honest twice over - low memory genuinely can change
   under us, which is why every read of it should be a real load. */
static const unsigned char *lowmem_bytes(unsigned long addr)
{
    volatile unsigned long opaque = addr;

    return (const unsigned char *)opaque;
}

/* V3. The current context's application name, out of low memory into
   the slot.

   Everything this routine is allowed to do is visible in it: a bounded
   byte loop over a fixed-size destination. No allocation, no Toolbox
   string call, no library memcpy, nothing that could move memory - this
   runs from the jGNE filter, inside whatever process is pumping, and
   the rules there are the same ones the rest of capture_anchor obeys.
   LMGetCurApName is an address constant (0x0910), not a trap, so
   reading it costs nothing and cannot fail.

   The length byte is written LAST, and cleared FIRST, for the reason
   the stamp is: it is this field's own commit word, and a length that
   arrives before the characters it counts describes bytes that are not
   there yet. Belt and braces beside the stamp, and free.

   Clamped to the field, never to the source: CurApName is documented as
   a Str31 but the multiversal headers note the low-memory area may be
   34 bytes, so the copy is bounded by what we WRITE, which is the only
   bound that is ours to know. */
static void capture_cur_ap_name(unsigned char *dst)
{
    const unsigned char *src = lowmem_bytes((unsigned long)LMGetCurApName());
    short len;
    short i;

    dst[0] = 0;                       /* invalidate before writing */
    if (src == NULL) {
        return;
    }
    len = (short)src[0];
    if (len > (short)(kNowPeekAnchorNameSize - 1)) {
        len = (short)(kNowPeekAnchorNameSize - 1);
    }
    for (i = 1; i <= len; ++i) {
        dst[i] = src[i];
    }
    dst[0] = (unsigned char)len;      /* commit */
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
    /* V2. Sits AFTER the stamp in the struct and BEFORE it in the write,
       which is the whole point: the stamp is this seqlock's commit, so
       anything written after it can be read paired with a stamp that does
       not cover it. Bounds an A5 world from the other end - the heap
       grows up from a5, the stack down from here - which is what lets a
       reader tell an address genuinely inside this process from one that
       merely looks like it. */
    slot->stack_base = (NowPeekU32)LMGetCurStackBase();
    /* V3. Same position-says-nothing-about-write-order rule: last field
       in the struct, still written before the stamp commits. This is the
       one captured value that is not an address, which is exactly why it
       can refute a slot that both addresses accept. */
    capture_cur_ap_name(slot->cur_ap_name);
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
    table->anchor_format = kNowPeekAnchorFormatV3;
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
