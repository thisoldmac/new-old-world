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
#include "now_ext_build_identity.h"
#include "now_ext_core_logic.h"

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

/* The act plane (now_ext_act.c), P4. Declared rather than included: the
   core knows one entry point and nothing else about it. */
extern void now_ext_act_apply(NowPeekTable *table);
/* P7's vehicle (now_ext_drag.c). */
extern void now_ext_drag_boot(NowPeekTable *table);
extern void now_ext_drag_abandon(NowPeekTable *table);
/* P8's cursor placement (now_ext_cursor.c). One entry point at boot,
   like P7's; the other one is called by P4 and P7 rather than by the
   core, which is the single exception this extension makes to "planes
   talk only through the core" and is made deliberately: putting the
   pointer somewhere is not a plane's own errand, it is a service both
   input planes need, and routing it through the core would mean the core
   knowing what a click is. */
extern void now_ext_cursor_boot(NowPeekTable *table);
extern void now_ext_cursor_gne(NowPeekTable *table);

/* The content plane (now_content.c), P3. Two entry points rather than
   P4's one, and the split is the plane's own: boot allocates and
   publishes, which may only happen at INIT time in the system heap, and
   gne decides the arm verdict, which may only happen in the process
   being asked about. Same rule otherwise - planes talk through the core
   and never to each other. */
extern void now_content_boot(NowPeekTable *table);
extern void now_content_gne(NowPeekTable *table);
/* P6: the liveness channel's Time Manager task (now_liveness.c), and the
   transport reachability probe. Two entry points for the same reason P3
   has two: one may only happen at INIT time, and the other may only
   happen anywhere BUT — MacTCP is not loaded at _start, and PBOpen is a
   blocking call no interrupt-time context may make. */
extern void now_liveness_install(NowPeekTable *table);
extern void now_liveness_probe_transport(NowPeekTable *table);
/* P5, the transition tail (now_event.c). Same two-entry shape, and the
   pass takes the words this filter has ALREADY read: two reads of
   LMGetWindowList in one pass could disagree, and a record that did not
   describe the same instant as the anchor beside it would be worse than
   no record. */
extern void now_event_boot(NowPeekTable *table);
extern void now_event_pass(NowPeekTable *table, NowPeekU32 ticks,
                           NowPeekU32 a5, NowPeekU32 window_list,
                           NowPeekU32 menu_list);
extern void now_semantic_apply(NowPeekTable *table, NowPeekU32 ticks);
extern void now_semantic_batch_apply(NowPeekTable *table, NowPeekU32 ticks);

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
static void capture_anchor(NowPeekU32 ticks)
{
    NowPeekU32 a5 = (NowPeekU32)LMGetCurrentA5();
    NowPeekU32 window_list;
    NowPeekAnchorSlot *slot;
    NowExtAnchorDecision decision;
    short idx;

    if (a5 == 0) {
        return;                       /* no valid A5 world to anchor */
    }
    if (a5 == gLastA5 && gLastSlot >= 0) {
        idx = gLastSlot;
    } else {
        gNowExtTable->anchor_slot_scans++;
        idx = find_anchor_slot(a5);
        gLastA5 = a5;
        gLastSlot = idx;
    }
    slot = &gNowExtTable->anchors[idx];
    window_list = (NowPeekU32)LMGetWindowList();
    decision = now_ext_anchor_decide(ticks, slot->stamp_ticks,
                                     a5, window_list,
                                     slot->a5, slot->window_list);
    if (decision == kNowExtAnchorSkip) {
        return;
    }
    if (slot->a5 == 0 && gAnchorCount < kNowPeekMaxAnchors) {
        gNowExtTable->anchor_count = ++gAnchorCount;
    }
    slot->stamp_ticks = 0;                          /* invalidate */
    slot->a5 = a5;
    slot->window_list = window_list;
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
    slot->stamp_ticks = ticks;                     /* commit last */
    gNowExtTable->anchor_full_publishes++;
    if (decision == kNowExtAnchorChanged) {
        gNowExtTable->anchor_change_publishes++;
    } else {
        gNowExtTable->anchor_cadence_publishes++;
    }
    gNowExtTable->anchor_last_publish_ticks = ticks;
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
    NowPeekU32 ticks;
    NowPeekU32 request;

    if (table == NULL) {
        return;
    }
    ticks = (NowPeekU32)LMGetTicks();
    table->heartbeat = ticks;
    /* THE DENOMINATOR, and it is bumped before any gate.
       ------------------------------------------------------------------
       Every other counter in this table is inside an arm. That makes them
       all unable to answer the question a resting machine actually poses:
       when `arms` and `hooked_ports` and `channel_sends` all read zero, is
       this component dark, or is it not running at all? Those are the two
       states this project has most often confused, and a negative with no
       denominator is exactly the shape of proof AGENTS.md refuses.

       One increment, unconditionally, so that "nothing armed" can be
       demonstrated rather than assumed: `gne_passes` climbing while every
       plane's counters stay flat IS the resting proof, and it is a
       cumulative resident counter diffed against itself rather than an
       absence anybody has to trust. */
    table->gne_passes++;
    /* P6's transport probe, once in the life of the machine. This is the
       only non-interrupt, post-boot context this component has, which is
       what the probe needs and cannot get anywhere else; it returns
       immediately on every pass after the first. */
    now_liveness_probe_transport(table);
    if (now_ext_writer_lease_valid(table, ticks)) {
        if (table->writer.resident_owner_epoch != table->writer.owner_epoch) {
            /* One dark pass separates writers. Patches consult the echoed
               epoch too, so the dead owner's request bypasses immediately. */
            table->writer.resident_owner_epoch = 0;
            request = 0;
        } else {
            request = table->arm_request;
        }
    } else {
        table->writer.resident_owner_epoch = 0;
        request = 0;
    }
    if (request & kNowPeekTableCapAnchors) {
        table->anchor_event_passes++;
        capture_anchor(ticks);
        table->arm_active |= kNowPeekTableCapAnchors;
    } else if (table->arm_active & kNowPeekTableCapAnchors) {
        table->arm_active &= ~(NowPeekU32)kNowPeekTableCapAnchors;
    }
    if (request & kNowPeekTableCapTree) {
        table->arm_active |= kNowPeekTableCapTree;
        now_semantic_apply(table, ticks);
        /* P2's second cell, on the same armed pass. Two cells means two
           bounded resolvers per pass rather than one - and the batch
           REPLACES up to 32 single-control requests that would each have
           paid their own hierarchy walk, so the pass gets cheaper per
           fact, not dearer. */
        now_semantic_batch_apply(table, ticks);
    } else if (table->arm_active & kNowPeekTableCapTree) {
        table->arm_active &= ~(NowPeekU32)kNowPeekTableCapTree;
    }
    /* P4, the act plane. Its own translation unit, reached only from
       here - planes talk through the core and never to each other
       (docs/resident-components.md). Disarmed, this costs the same load
       and branch the anchor arm above costs; the plane's own first act
       is to return when no request names the process we are running as.

       The arm bit does more work here than it does for P1: it is also
       the plane's bypass switch, so clearing it makes six trap patches
       chain straight through. The patches themselves are installed on
       the first armed pass and never removed - a patch that vanishes
       while a caller is inside it is a jump into freed code. */
    if (request & kNowPeekTableCapAct) {
        now_ext_act_apply(table);
        table->arm_active |= kNowPeekTableCapAct;
    } else if (table->arm_active & kNowPeekTableCapAct) {
        table->arm_active &= ~(NowPeekU32)kNowPeekTableCapAct;
        /* P7: disarming the act plane while a button is held must not
           leave it held. The vehicle's own dead-man would get there
           within a second anyway - this is the same release, arriving at
           the moment the intent is withdrawn rather than at the deadline,
           and recorded as SessionLost so nothing downstream reads a
           withdrawn gesture as one that completed. */
        now_ext_drag_abandon(table);
    }
    /* P3, the content plane. Unlike the two above, the arm handshake is
       not decided here: this plane's request names an A5 world, and only
       the process pumping can say whether it is the one named - so the
       whole verdict, arm and disarm both, lives in now_content_gne and
       this is the call that lets it run. Disarmed it is a load, a null
       check and a return. */
    /* P8. Settles a redraw the drag vehicle owed from interrupt time -
       the drawing route is QuickDraw and this is the first context since
       the placement in which it may be called. Ungated on purpose: a
       picture that disagrees with the machine is not made correct by
       disarming a plane. Nothing owed costs a load and a return. */
    now_ext_cursor_gne(table);
    now_content_gne(table);
    /* P5. Its own arm verdict, like P3's, because it also names an A5
       world. Disarmed it is a load, a null check and a return. */
    now_event_pass(table, ticks, (NowPeekU32)LMGetCurrentA5(),
                   (NowPeekU32)LMGetWindowList(),
                   (NowPeekU32)LMGetMenuList());
    if (request == 0 && now_ext_writer_lease_valid(table, ticks)
        && table->writer.resident_owner_epoch == 0) {
        table->writer.resident_owner_epoch = table->writer.owner_epoch;
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
    table->ext_minor = kNowPeekExtMinor;
    /* The anchor region is real, backed memory now (P1), so length
       covers the whole table; the app still trusts an individual slot
       only when the plane is armed and the slot's stamp is fresh. */
    table->length = (NowPeekU32)sizeof(NowPeekTable);
    /* P1 and P4 are AVAILABLE but dark: advertised in caps, and neither
       captures nor patches anything until the app writes arm_request.
       Capabilities are bits and never inferred from a version, which is
       what lets a plane ship in a binary before it has earned metal
       verification - and P4 has not. */
    table->caps = kNowPeekTableCapAnchors | kNowPeekTableCapTree
                | kNowPeekTableCapAct;
    table->boot_ticks = (NowPeekU32)LMGetTicks();
    table->heartbeat = table->boot_ticks;
    table->arm_request = 0;
    table->arm_active = 0;
    /* Set BEFORE the planes boot, because they are what fill the word:
       the content plane claims its block below and the filter claims
       itself further down, and a bit arriving before the format word that
       says how to read it would be a bit no reader is allowed to trust. */
    table->rest_format = kNowPeekRestFormatV1;
    table->rest_state = 0;
    table->gne_passes = 0;
    table->anchor_format = kNowPeekAnchorFormatV3;
    table->anchor_count = 0;
    /* P3, and the position in this sequence is the point. It allocates
       its block, installs its QuickDraw procs, and publishes both the
       block's address and its capability bit - so it must run AFTER the
       fields above are set and BEFORE `magic` commits, or a reader that
       sees the table the instant it becomes valid could find it without
       the content cap while the plane is in fact present. A plane that
       exists and does not advertise is worse than one that is absent:
       absent is a state the product handles. */
    now_content_boot(table);
    now_event_boot(table);
    /* P4's own format word, and the buffer size THIS binary allocated.
       Both are what an application gates on before it writes a request:
       an extension that predates the plane reports a shorter `length`,
       and the application refuses rather than writing off the end of a
       system-heap block it did not size. */
    /* P7's vehicle, and its position here is the same argument P3's is:
       it installs a Time Manager task and publishes its own capability
       bit, so it must run before `magic` commits. It does NOT prime the
       task - a machine that never drags anything pays nothing - and it
       publishes kNowPeekTableCapDrag only if the install succeeded, so an
       application never arms a vehicle that cannot fire. */
    now_ext_drag_boot(table);
    /* P8, and it must come after P7 for no reason other than reading
       order - it installs nothing and primes nothing. It asks the Cursor
       Device Manager for a device once, and publishes
       kNowPeekTableCapCursor only if it got one, so an application never
       believes the sprite will follow on a machine where it cannot. */
    now_ext_cursor_boot(table);
    table->act_format = kNowPeekActFormatV2;
    table->act_text_max = (NowPeekU16)kNowPeekActTextMax;
    table->identity_format = kNowPeekIdentityFormatV1;
    table->identity_length = (NowPeekU16)sizeof table->identity;
    table->identity.source_manifest[0] = NOW_EXT_SOURCE_MANIFEST_0;
    table->identity.source_manifest[1] = NOW_EXT_SOURCE_MANIFEST_1;
    table->identity.source_manifest[2] = NOW_EXT_SOURCE_MANIFEST_2;
    table->identity.source_manifest[3] = NOW_EXT_SOURCE_MANIFEST_3;
    table->identity.source_manifest[4] = NOW_EXT_SOURCE_MANIFEST_4;
    table->identity.build_fingerprint[0] = NOW_EXT_BUILD_FINGERPRINT_0;
    table->identity.build_fingerprint[1] = NOW_EXT_BUILD_FINGERPRINT_1;
    table->identity.build_fingerprint[2] = NOW_EXT_BUILD_FINGERPRINT_2;
    table->identity.build_fingerprint[3] = NOW_EXT_BUILD_FINGERPRINT_3;
    table->identity.build_fingerprint[4] = NOW_EXT_BUILD_FINGERPRINT_4;
    table->writer_format = kNowPeekWriterFormatV1;
    table->writer_length = (NowPeekU16)sizeof table->writer;
    table->semantic_format = kNowPeekSemanticFormatV2;
    table->semantic_length = (NowPeekU16)sizeof table->semantic;
    /* P2's second cell advertises itself the same accretive way: this
       binary's `length` reaches it and this pair claims it. An older
       extension is simply shorter, and the application falls back to the
       single-control op without being told to. */
    table->semantic_batch_format = kNowPeekSemanticBatchFormatV1;
    table->semantic_batch_length = (NowPeekU16)sizeof table->semantic_batch;
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
    /* Reported, not assumed. This is the one hook that never stands down —
       it is what would notice a re-arm, so it has to outlive every plane
       it gates — and saying so in the table is what lets a reader check
       the claim instead of taking it from a comment. */
    table->rest_state |= (NowPeekU16)kNowPeekRestGNEFilter;

    /* P6, the extension's first INTERRUPT-time context, installed last
       for the same reason the filter is: a callback that can fire must
       not be able to find a half-built world. Everything above runs only
       when some application calls GetNextEvent or a patched trap — which
       is exactly what a starved machine has none of. */
    now_liveness_install(table);

    /* Resident forever: no Retro68FreeGlobals(), no unwind past here. */
}
