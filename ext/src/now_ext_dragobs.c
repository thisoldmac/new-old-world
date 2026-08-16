/*
 * now_ext_dragobs.c - V14, the drag observer.
 *
 * WHY THIS EXISTS AT ALL, AND WHY IT CANNOT LIVE IN THE APPLICATION
 * -----------------------------------------------------------------
 * The PowerPC application receives ZERO task time inside a Finder drag
 * loop - twenty-one seconds of probe, not one line (2026-08-15). No
 * poll, no AppleEvent, no task-time anything on that side can see a drag
 * begin. Foreign-context execution lives only in a resident component
 * (docs/resident-components.md), so if a drag is to be seen at all, it
 * is seen from here.
 *
 * WHAT IT OBSERVES, AND WHAT IT MUST NEVER DO
 * --------------------------------------------
 * Slice 1 is observe-only. The shim in now_ext_dragobs_patch.S chains
 * unconditionally - there is no path through it that declines a call,
 * substitutes a result, or writes to a caller's result slot. Everything
 * this file does is read something and put it in a cell. The peek
 * table's own comment says it: nothing in the resident reads this block
 * back, and no decision anywhere consults it.
 *
 * THE RE-ENTRANCY RULE, WHICH IS THE ONE THAT WOULD HANG A MACHINE
 * ----------------------------------------------------------------
 * Every Drag Manager call is the same trap. So CountDragItems and
 * GetFlavorData and GetDragMouse - the calls this observer makes to
 * learn anything at all - come straight back through the shim that
 * called it. `gInside` is therefore not defensive habit; without it the
 * first drag on the machine recurses until the stack is gone. It is set
 * before any Drag Manager call and cleared after, and while it is set
 * the shim's C side does nothing but count the visit and return.
 *
 * INTERRUPT AND MEMORY RULES
 * ---------------------------
 * TrackDrag is called at TASK time, in the dragging application, so the
 * Memory Manager rules that apply are that application's. This file
 * still allocates nothing: the record is a pre-existing cell in the
 * resident's system-heap table, the flavor is read into an 80-byte
 * automatic, and the prologue before the first guard is a load and two
 * compares. Nothing here calls the File Manager, moves memory, or waits.
 *
 * WHAT A ZERO MEANS HERE
 * -----------------------
 * The Mac OS 9 Finder is a PowerPC application and the Drag Manager is
 * native PowerPC code. Whether a PPC caller's TrackDrag reaches the 68K
 * trap table is NOT known at the time of writing and is precisely what
 * this slice measures. So the counters are laid out to distinguish "the
 * trap was not patchable" from "the patch is in and nothing calls
 * through it" from "drags come through and we could not read one" - see
 * the block comment on NowPeekDragObserve. An instrument that cannot
 * tell absence from defect reports them in the same words, and this
 * project has already paid for one that could not.
 */
#include <MacTypes.h>
#include <Drag.h>
#include <Events.h>
#include <Files.h>
#include <LowMem.h>
#include <Traps.h>

#include "peek_table.h"
#include "now_ext_dragobs.h"

/* _DragDispatch. One trap, selectors in D0; TrackDrag is 13, from the
   TWOWORDINLINE on TrackDrag's own declaration (Universal Interfaces
   3.4, `0x700D, 0xABED` - `moveq #13,%d0`), not from memory and not
   from a disassembly. */
#define kNowDragObsDispatchTrap 0xABED
#define kNowDragObsSelTrackDrag 13u

/* Referenced from assembly, so plain module globals with external
   linkage - the same shape the act plane's saved traps have. */
void *gNowDragObsOldDispatch = NULL;
void *gNowDragObsSavedReturn = NULL;

extern void now_dragobs_patch(void);
extern void now_dragobs_return_thunk(void);

int now_dragobs_enter(unsigned long selector, void *theEvent, void *theDrag);
void now_dragobs_leave(long result);

static NowPeekTable *gTable;
/* The one flag that keeps a machine alive: our own Drag Manager calls
   re-enter the shim, and while this is set the shim's C side counts the
   visit and returns without touching the Drag Manager again. */
static volatile int gInside;
/* Set between swapping in the return thunk and the thunk running. A
   second TrackDrag arriving in that window is observed at entry and NOT
   intercepted, because there is one saved-return slot and overwriting it
   would send a caller somewhere else entirely. */
static volatile int gReturnPending;
/* The DragRef TrackDrag was handed. Samples taken on OTHER selectors use
   this, never the stack slot they rode in on: argument positions differ
   per selector, so that slot means something different for every call
   and is only a DragRef for selector 13. */
static DragRef gLiveDrag;
static NowPeekU32 gLastSampleTicks;

static NowPeekContinuityCell *dragobs_cell(NowPeekTable *table)
{
    if (table == NULL || table->magic != (NowPeekU32)kNowPeekTableMagic)
        return NULL;
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, continuity)
                                     + sizeof(NowPeekContinuityCell)))
        return NULL;
    if (table->continuity_format
            != (NowPeekU32)NOW_CONTINUITY_FORMAT_CURRENT)
        return NULL;
    if (!(table->caps & (NowPeekU32)kNowPeekTableCapContinuity))
        return NULL;
    return &table->continuity;
}

/* The cell, or NULL, from inside the shim. Deliberately separate from
   the resolver above: this one runs on EVERY Drag Manager call in the
   machine, so it is a pointer load and one compare, and it must be
   correct when the plane has never been armed. */
static NowPeekDragObserve *shim_block(void)
{
    NowPeekContinuityCell *cell = dragobs_cell(gTable);

    if (cell == NULL)
        return NULL;
    return &cell->drag_observe;
}

/* ---- installation, on every armed pass -------------------------------
 *
 * Once-per-boot was the act plane's original mistake and it measured
 * exactly the failure this plane would inherit: the install always
 * landed in NOW's own context, because NOW's application is the one
 * pumping the wire the request arrived on, and a patch in the wrong
 * dispatch table is a patch no foreign application ever calls. So this
 * runs per armed pass and is idempotent by identity check.
 *
 * The patch is never removed. Unpatching is more dangerous than
 * patching: another extension may have chained behind ours, and taking a
 * link out of the middle of a chain is a jump into freed code. Disarming
 * instead makes the C side decline to record, and the shim chains
 * exactly as it would with no extension present. */
static void dragobs_install(NowPeekDragObserve *block)
{
    void *unimpl;
    void *old;

    block->install_passes++;
    if (block->install_state == (NowPeekU32)kNowPeekDragObsInstallDone)
        return;

    /* A machine with no Drag Manager answers with the Unimplemented
       handler. That is a correct and final answer, not a defect, and it
       is the one case an absent capability must not read as a broken
       one. */
    unimpl = (void *)NGetTrapAddress(_Unimplemented, ToolTrap);
    old = (void *)NGetTrapAddress(kNowDragObsDispatchTrap, ToolTrap);
    if (old == NULL || old == unimpl) {
        block->install_state = (NowPeekU32)kNowPeekDragObsInstallNoTrap;
        return;
    }
    /* ALREADY OURS IN THIS DISPATCH TABLE. Saving `old` here would point
       the chain at our own shim and the first drag would loop until the
       machine stopped. With the check a second install is a no-op under
       a system-wide trap table and a real install under a per-context
       one - correct either way, which is the point, because which one
       this machine has is exactly what is not yet known. */
    if (old == (void *)now_dragobs_patch) {
        block->install_state = (NowPeekU32)kNowPeekDragObsInstallDone;
        return;
    }
    gNowDragObsOldDispatch = old;
    NSetTrapAddress((UniversalProcPtr)now_dragobs_patch,
                    kNowDragObsDispatchTrap, ToolTrap);
    block->install_state = (NowPeekU32)kNowPeekDragObsInstallDone;
}

/* ---- the control ------------------------------------------------------
 *
 * WHY THIS EXISTS, in one sentence: without it `dispatches == 0` means
 * either "nothing in this machine calls the Drag Manager through the 68K
 * trap" or "our shim is not actually in anybody's path", and those are
 * opposite conclusions about opposite systems.
 *
 * The first emulator round hit that wall exactly. A harness-driven
 * Finder drag produced `install=1 disp=0`, and nothing in the reading
 * distinguished a PowerPC Finder bypassing the 68K trap table from a
 * Finder that never started a drag at all.
 *
 * So the plane makes ONE Drag Manager call of its own, from 68K code we
 * compiled, once per boot, on the first armed pass, and OUTSIDE the
 * re-entrancy guard - which is the whole trick: if the shim is in the
 * path, this call must come back through it and `dispatches` must move.
 *
 * NewDrag/DisposeDrag is the pair chosen because it touches no drag
 * anybody else owns, no window, no file and no foreign state: it asks
 * the Drag Manager for a reference and hands it straight back. It runs
 * at task time in whatever process is pumping, which is where the act
 * plane's own selftest runs a real MenuSelect, for the same reason.
 *
 * A control that cannot fail proves nothing, so all three outcomes are
 * recorded and `Blind` is a defect in THIS PLANE rather than a fact
 * about anybody's Finder. */
static void dragobs_selftest(NowPeekDragObserve *block)
{
    NowPeekU32 before;
    DragRef probe = NULL;
    OSErr err;

    if (block->install_state != (NowPeekU32)kNowPeekDragObsInstallDone)
        return;
    if (block->selftest_state != (NowPeekU32)kNowPeekDragObsSelftestUntried)
        return;                       /* once per boot, and only once */

    before = block->dispatches;
    err = NewDrag(&probe);
    if (err != noErr || probe == NULL) {
        block->selftest_state = (NowPeekU32)kNowPeekDragObsSelftestRefused;
        block->selftest_err = (NowPeekI32)err;
        return;
    }
    (void)DisposeDrag(probe);
    block->selftest_seen = block->dispatches - before;
    block->selftest_state = block->selftest_seen != 0
        ? (NowPeekU32)kNowPeekDragObsSelftestSeen
        : (NowPeekU32)kNowPeekDragObsSelftestBlind;
}

/* WHICH ARM SWITCHES THIS ON, and why it is two rather than one.
 *
 * The obvious answer is Continuity, and Continuity alone was the first
 * one written. It is too narrow, and the reason is not a testing
 * convenience: THE POINTER IS DRIVEN BY TWO PLANES. P9 drives it from a
 * host's Continuity pass; P4/P7 drive it from an act request, and P7's
 * vehicle is the one that can hold the button down through a Finder
 * tracking loop. The whole question this observer exists to answer -
 * what does Drag Manager targeting consult while a DRIVEN pointer moves
 * - is a question about both of them, and an instrument armed for one
 * would report an honest zero for every drag the other made.
 *
 * The charter property is unchanged either way: a machine that never
 * opens the mirror and never sends an act arms neither, and its trap
 * table is untouched. */
void now_ext_dragobs_gne(NowPeekTable *table, NowPeekU32 request)
{
    NowPeekContinuityCell *cell = dragobs_cell(table);
    int continuity_armed;

    if (cell == NULL)
        return;
    continuity_armed = cell->enabled
        && (cell->state == (NowPeekU32)kNowPeekContinuityStateArmed
            || cell->state == (NowPeekU32)kNowPeekContinuityStateActive);
    if (!continuity_armed
            && !(request & (NowPeekU32)kNowPeekTableCapAct))
        return;
    gTable = table;
    dragobs_install(&cell->drag_observe);
    dragobs_selftest(&cell->drag_observe);
}

/* ---- reading a drag ---------------------------------------------------
 *
 * Every function below runs with gInside already set by its caller, so
 * the Drag Manager calls it makes chain straight through the shim. */

static void read_identity(NowPeekDragObserve *block, DragRef drag)
{
    HFSFlavor flavor;
    DragItemRef item = 0;
    UInt16 count = 0;
    Size size = 0;
    OSErr err;
    int i;

    block->item_status = (NowPeekU32)kNowPeekDragObsItemUnknown;
    block->item_err = 0;
    block->item_count = 0;
    block->file_type = 0;
    block->file_creator = 0;
    block->file_vrefnum = 0;
    block->file_parid = 0;
    for (i = 0; i < 64; ++i)
        block->file_name[i] = 0;

    err = CountDragItems(drag, &count);
    if (err != noErr) {
        block->item_status = (NowPeekU32)kNowPeekDragObsItemError;
        block->item_err = (NowPeekI32)err;
        return;
    }
    /* The honest count, whatever it is. An over-count is reported as the
       number it is and never collapsed into the first item's identity:
       `item_status` describes ITEM ONE and says so in the contract. */
    block->item_count = (NowPeekU32)count;
    if (count == 0) {
        block->item_status = (NowPeekU32)kNowPeekDragObsItemNoHFS;
        return;
    }
    err = GetDragItemReferenceNumber(drag, 1, &item);
    if (err != noErr) {
        block->item_status = (NowPeekU32)kNowPeekDragObsItemError;
        block->item_err = (NowPeekI32)err;
        return;
    }
    size = (Size)sizeof(flavor);
    err = GetFlavorData(drag, item, flavorTypeHFS, &flavor, &size, 0);
    if (err != noErr) {
        /* No HFS flavor. A promise is a DIFFERENT answer - the sender has
           a file to give and has not made it yet - and reporting it as an
           FSSpec we do not have is exactly the guess this block refuses
           to make. */
        Size promise = 0;

        if (GetFlavorDataSize(drag, item, flavorTypePromiseHFS, &promise)
                == noErr) {
            block->item_status = (NowPeekU32)kNowPeekDragObsItemPromise;
            return;
        }
        block->item_status = (NowPeekU32)kNowPeekDragObsItemNoHFS;
        block->item_err = (NowPeekI32)err;
        return;
    }
    if (size < (Size)sizeof(flavor)) {
        /* Short read: something answered, but not with an HFSFlavor. */
        block->item_status = (NowPeekU32)kNowPeekDragObsItemError;
        block->item_err = (NowPeekI32)size;
        return;
    }
    block->item_status = (NowPeekU32)kNowPeekDragObsItemHFS;
    block->file_type = (NowPeekU32)flavor.fileType;
    block->file_creator = (NowPeekU32)flavor.fileCreator;
    block->file_vrefnum = (NowPeekI32)flavor.fileSpec.vRefNum;
    block->file_parid = (NowPeekU32)flavor.fileSpec.parID;
    /* Copied by value into fixed width. A pointer into a foreign heap
       would be read after that heap may be gone - the same rule
       `guest_name` follows in the same table. Byte 0 is the Pascal
       length, so the copy is bounded by both it and the field. */
    {
        int len = (int)flavor.fileSpec.name[0];

        if (len > 62)
            len = 62;
        block->file_name[0] = (unsigned char)len;
        for (i = 0; i < len; ++i)
            block->file_name[i + 1] = flavor.fileSpec.name[i + 1];
    }
}

/* One look at a live drag. The whole point is the DIFFERENCE between
   what the Drag Manager reports and the low-memory point this resident
   is driving: `feat/hg-drag-dragmgr` measured targeting believing
   `inwin=1` while GetMouse read the true point and could not see which
   side of the Drag Manager the disagreement began on. */
static void take_sample(NowPeekDragObserve *block, unsigned long selector,
                        NowPeekU32 ticks)
{
    NowPeekDragObsSample *slot;
    Point dm_mouse, dm_pinned, lm_raw, lm_mouse;
    DragAttributes attrs = 0;
    SInt16 mods = 0, down_mods = 0, up_mods = 0;
    OSErr err;
    NowPeekU32 index;

    if (block->sample_count >= (NowPeekU32)kNowPeekDragObsSampleCapacity)
        block->sample_dropped++;
    index = block->sample_count % (NowPeekU32)kNowPeekDragObsSampleCapacity;
    slot = &block->samples[index];

    dm_mouse.h = 0; dm_mouse.v = 0;
    dm_pinned.h = 0; dm_pinned.v = 0;
    slot->err = 0;
    err = GetDragMouse(gLiveDrag, &dm_mouse, &dm_pinned);
    if (err != noErr && slot->err == 0)
        slot->err = (NowPeekI32)err;
    err = GetDragAttributes(gLiveDrag, &attrs);
    if (err != noErr && slot->err == 0)
        slot->err = (NowPeekI32)err;
    err = GetDragModifiers(gLiveDrag, &mods, &down_mods, &up_mods);
    if (err != noErr && slot->err == 0)
        slot->err = (NowPeekI32)err;

    lm_raw = LMGetRawMouseLocation();
    lm_mouse = LMGetMouseLocation();

    slot->ticks = ticks;
    slot->selector = (NowPeekU32)selector;
    slot->dm_mouse_h = (NowPeekI32)dm_mouse.h;
    slot->dm_mouse_v = (NowPeekI32)dm_mouse.v;
    slot->dm_pinned_h = (NowPeekI32)dm_pinned.h;
    slot->dm_pinned_v = (NowPeekI32)dm_pinned.v;
    slot->lm_raw_h = (NowPeekI32)lm_raw.h;
    slot->lm_raw_v = (NowPeekI32)lm_raw.v;
    slot->lm_mouse_h = (NowPeekI32)lm_mouse.h;
    slot->lm_mouse_v = (NowPeekI32)lm_mouse.v;
    slot->attributes = (NowPeekU32)attrs;
    slot->modifiers = (NowPeekU32)(unsigned short)mods;
    slot->reserved0 = 0;
    /* Bumped LAST: a reader deriving the ring index from this count can
       never be pointed at a slot that is still being written. */
    block->sample_count++;
}

/* ---- the shim's C side ------------------------------------------------
 *
 * Called on EVERY Drag Manager call in the machine. The prologue before
 * the first return is a pointer load and two compares, deliberately. */
int now_dragobs_enter(unsigned long selector, void *theEvent, void *theDrag)
{
    NowPeekDragObserve *block = shim_block();
    NowPeekU32 ticks;

    if (block == NULL)
        return 0;
    if (gInside) {
        /* Our own nested call. Counted so that "this observer is talking
           to itself" is a number rather than an inference. */
        block->reentries++;
        return 0;
    }
    block->dispatches++;

    ticks = (NowPeekU32)LMGetTicks();
    if (selector != (unsigned long)kNowDragObsSelTrackDrag) {
        /* Not a drag beginning - but if one is RUNNING, this is a free
           look at it from inside the tracking loop, which is the only
           place a look can be had. Bounded by a tick gap and a ring. */
        if (gReturnPending
                && (ticks - gLastSampleTicks)
                    >= (NowPeekU32)kNowPeekDragObsSampleGapTicks) {
            gLastSampleTicks = ticks;
            gInside = 1;
            take_sample(block, selector, ticks);
            gInside = 0;
        }
        return 0;
    }

    block->trackdrag_entries++;
    if (gReturnPending) {
        /* A nested TrackDrag. There is one saved-return slot; taking a
           second would send the outer caller somewhere else entirely.
           Observed and not intercepted, which is the safe half. */
        return 0;
    }

    gInside = 1;
    /* Odd while the record is being written; even, and bumped LAST, when
       it is whole. */
    block->begin_seq++;
    block->begin_ticks = ticks;
    block->end_ticks = 0;                 /* the end is not here yet */
    block->entry_a5 = (NowPeekU32)LMGetCurrentA5();
    block->drag_ref = (NowPeekU32)theDrag;
    block->result = 0;
    block->final_h = 0;
    block->final_v = 0;
    block->sample_count = 0;
    block->sample_dropped = 0;
    gLastSampleTicks = ticks;

    /* What the Drag Manager was HANDED. theEvent is only an EventRecord
       for this selector, which is why it is dereferenced here and
       nowhere else in this file. */
    if (theEvent != NULL) {
        const EventRecord *event = (const EventRecord *)theEvent;

        block->event_where_h = (NowPeekI32)event->where.h;
        block->event_where_v = (NowPeekI32)event->where.v;
        block->event_when = (NowPeekU32)event->when;
        block->event_modifiers = (NowPeekU32)(unsigned short)event->modifiers;
    } else {
        block->event_where_h = 0;
        block->event_where_v = 0;
        block->event_when = 0;
        block->event_modifiers = 0;
    }

    gLiveDrag = (DragRef)theDrag;
    {
        Point origin;
        DragAttributes attrs = 0;

        origin.h = 0;
        origin.v = 0;
        (void)GetDragOrigin(gLiveDrag, &origin);
        (void)GetDragAttributes(gLiveDrag, &attrs);
        block->origin_h = (NowPeekI32)origin.h;
        block->origin_v = (NowPeekI32)origin.v;
        block->entry_attributes = (NowPeekU32)attrs;
    }
    read_identity(block, gLiveDrag);
    block->begin_seq++;                   /* committed */
    gInside = 0;

    gReturnPending = 1;
    return 1;
}

/* TrackDrag returned. Called from the thunk, still at task time in the
   dragging application, with the caller's result already read off its
   own stack slot and never written back. */
void now_dragobs_leave(long result)
{
    NowPeekDragObserve *block = shim_block();
    Point raw;

    gReturnPending = 0;
    if (block == NULL)
        return;
    block->trackdrag_returns++;
    block->end_seq++;
    block->result = (NowPeekI32)result;
    block->end_ticks = (NowPeekU32)LMGetTicks();
    raw = LMGetRawMouseLocation();
    block->final_h = (NowPeekI32)raw.h;
    block->final_v = (NowPeekI32)raw.v;
    block->end_seq++;                     /* committed */
    gLiveDrag = NULL;
}
