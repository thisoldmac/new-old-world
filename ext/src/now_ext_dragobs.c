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
#include <MixedMode.h>
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

/* ONE identity reader behind TWO routes, declared here because the
   registration route below is written before it. The trap route and the
   handler route read the dragged file the same way and write into
   different fields, so a disagreement between the two readings would be
   a real finding rather than a difference in how they asked. */
static void read_identity_into(NowPeekDragObserve *block, DragRef drag,
                               NowPeekU32 *out_count, NowPeekU32 *out_status,
                               NowPeekI32 *out_err, NowPeekU32 *out_type,
                               NowPeekU32 *out_creator, NowPeekI32 *out_vref,
                               NowPeekU32 *out_parid, unsigned char *out_name);

/* The resident's own connection to the host, declared at its use site the
   way now_liveness.c declares the rest of that channel. Task time only -
   see the four rules on it in now_liveness_net.c. */
extern int now_liveness_net_send_drag(NowPeekTable *table, NowPeekU32 epoch,
                                      NowPeekU32 seq, NowPeekU32 ticks,
                                      NowPeekU32 file_type,
                                      NowPeekU32 creator, NowPeekI32 vref,
                                      NowPeekU32 parid,
                                      const unsigned char *name);

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

/* ======================================================================
   V15 - THE REGISTRATION ROUTE
   ======================================================================

   WHY THERE IS A SECOND ROUTE. The first one is measured and it does not
   exist: a 68K patch on `_DragDispatch` is provably live (the control
   above sees its own two calls) and a PowerPC Finder completes a whole
   file drag without one dispatch through it. So this route stops
   patching anything and uses the public door.

   `InstallTrackingHandler` registers a handler FOR THE CALLING
   APPLICATION. That is the whole reason it can work where the patch
   could not, and also the whole reason it must be done from here: the
   registration belongs to whichever process is current when the call is
   made, and the jGNE armed pass is the only place this component is ever
   inside somebody else's process.

   THREE CHARTER QUESTIONS, ANSWERED IN CODE RATHER THAN IN A COMMENT.

   1. THE UPP IS NOT A CAST. It is a real RoutineDescriptor, built by
      `BUILD_ROUTINE_DESCRIPTOR` with the procInfo Universal Interfaces
      declares for this callback. The Drag Manager on this machine is
      native PowerPC and our handler is 68K, so it is reached through
      Mixed Mode, and Mixed Mode needs a descriptor that says so.

   2. NOTHING IS ALLOCATED, EVER. `NewDragTrackingHandlerUPP` allocates,
      and it would allocate IN THE FOREIGN APPLICATION'S HEAP, which is
      the one thing a resident may not do from a hook. So the descriptor
      is a module global - the resident's own relocated storage, which
      lives in the system heap and is reachable from every context, the
      same property the trap trampolines already depend on. It is filled
      in at runtime from a local initializer rather than being statically
      initialised, because this INIT is RELOCATED at load
      (RETRO68_RELOCATE) and a procedure address baked into static data
      is the kind of thing that is either fixed up or is a jump into
      nowhere. Assigning from a local makes the compiler load the
      relocated address, and removes the question.

   3. WHAT THE HANDLER TOUCHES. The cell is the resident's system-heap
      table, addressed absolutely; the handler's own code and globals are
      the resident's. Nothing it reads or writes belongs to the
      application it is running inside. Its Drag Manager calls go back
      out through our own trap shim, so they are inside the same
      re-entrancy guard everything else here uses.

   UN-REGISTRATION IS THE HARD HALF, and it is hard for a reason worth
   stating: a registration is per-application, so it can only be REMOVED
   from the same application it was made in - and a disarm arrives on
   whatever process happens to be pumping, which is usually not that one.
   A handler left behind in the Finder after the pass ends is exactly the
   leak the per-pass rule exists to prevent, and it is worse than a
   leaked patch, because the Drag Manager will go on calling into a
   plane that has been told to stand down.

   So the plane keeps the A5 of every context it registered in, and
   removes the registration when it is next inside that context and the
   arm is gone. `handler_installs` and `handler_removes` are published
   so the pairing is a number a reader can check rather than a claim
   this comment makes. */

/* The handler. Runs in the DRAGGING APPLICATION's context, called by the
   Drag Manager through Mixed Mode, at task time. Deliberately small: it
   reads, it writes the cell, it returns noErr. It never declines, never
   changes the drag, and never returns anything but noErr, because a
   tracking handler's result is consulted and this plane observes. */
static pascal OSErr now_dragobs_tracking(DragTrackingMessage message,
                                         WindowRef theWindow,
                                         void *refCon, DragRef theDrag);

static RoutineDescriptor gTrackDesc;
static Boolean gTrackDescReady;
/* The A5 worlds currently holding one of our registrations. This is what
   un-registration is driven from: a registration we have forgotten is
   one we can never remove. */
static NowPeekU32 gTrackContexts[kNowPeekDragObsContextCapacity];
static int gTrackContextCount;

static DragTrackingHandlerUPP track_upp(void)
{
    if (!gTrackDescReady) {
        /* Built from a LOCAL initializer, not statically - see the
           relocation argument above. No allocation on either path. */
        RoutineDescriptor built = BUILD_ROUTINE_DESCRIPTOR(
            uppDragTrackingHandlerProcInfo, now_dragobs_tracking);

        gTrackDesc = built;
        gTrackDescReady = true;
    }
    return (DragTrackingHandlerUPP)&gTrackDesc;
}

static int track_context_index(NowPeekU32 a5)
{
    int i;

    for (i = 0; i < gTrackContextCount; ++i) {
        if (gTrackContexts[i] == a5)
            return i;
    }
    return -1;
}

/* Register in THIS context if we have not already. `theWindow` is NULL,
   which the Drag Manager reads as "every window this application owns" -
   the Finder's icons live on the desktop window and in folder windows
   and we have no business enumerating either. */
/* V16. One attempt, named, with its outcome. See the contract for why
   this is a row per ATTEMPT rather than a counter of successes. */
static void track_note(NowPeekDragObserve *block, NowPeekU32 a5, NowPeekI32 err)
{
    if (block->reg_count < (NowPeekU32)kNowPeekDragObsRegCapacity) {
        NowPeekDragObsReg *reg = &block->regs[block->reg_count];
        /* Through a volatile, for the reason now_ext.c states once: low
           memory is the SYSTEM's storage and not an array the compiler
           declared, so a direct deref is an out-of-bounds read as far as
           it is concerned - and it is right to say so. */
        volatile unsigned long opaque = (unsigned long)LMGetCurApName();
        const unsigned char *src = (const unsigned char *)opaque;
        short len = 0;
        short i;

        reg->a5 = a5;
        reg->ticks = (NowPeekU32)LMGetTicks();
        reg->err = err;
        for (i = 0; i < 32; ++i)
            reg->name[i] = 0;
        /* Bounded by what we WRITE, never by the source: CurApName is
           documented Str31 and the low-memory area may be 34 bytes. */
        if (src != NULL) {
            len = (short)src[0];
            if (len > 30)
                len = 30;
            for (i = 0; i <= len; ++i)
                reg->name[i] = src[i];
            reg->name[0] = (unsigned char)len;
        }
    }
    block->reg_count++;
}

/* V17. Count this pass against whatever application is pumping, BEFORE
   any gate. See the contract: the attempt rows cannot tell "never pumped"
   from "pumped while the predicate was false", and this can. */
static void pump_note(NowPeekDragObserve *block, NowPeekU32 a5, int armed)
{
    NowPeekU32 i;
    NowPeekDragObsPump *row = (NowPeekDragObsPump *)0;

    for (i = 0; i < block->pump_count
                && i < (NowPeekU32)kNowPeekDragObsPumpCapacity; ++i) {
        if (block->pumps[i].a5 == a5) {
            row = &block->pumps[i];
            break;
        }
    }
    if (row == (NowPeekDragObsPump *)0) {
        if (block->pump_count >= (NowPeekU32)kNowPeekDragObsPumpCapacity) {
            block->pump_count++;      /* uncapped, so overflow is visible */
            return;
        }
        row = &block->pumps[block->pump_count];
        {
            /* Through a volatile: low memory is the SYSTEM's storage, not
               an array the compiler declared. */
            volatile unsigned long opaque = (unsigned long)LMGetCurApName();
            const unsigned char *src = (const unsigned char *)opaque;
            short len = 0;
            short j;

            row->a5 = a5;
            row->passes = 0;
            row->armed_passes = 0;
            for (j = 0; j < 32; ++j)
                row->name[j] = 0;
            if (src != NULL) {
                len = (short)src[0];
                if (len > 30)
                    len = 30;
                for (j = 0; j <= len; ++j)
                    row->name[j] = src[j];
                row->name[0] = (unsigned char)len;
            }
        }
        block->pump_count++;
    }
    row->passes++;
    if (armed)
        row->armed_passes++;
}

static void track_install(NowPeekDragObserve *block, NowPeekU32 a5)
{
    OSErr err;

    if (track_context_index(a5) >= 0)
        return;
    if (gTrackContextCount >= kNowPeekDragObsContextCapacity) {
        block->handler_state = (NowPeekU32)kNowPeekDragObsHandlerNoRoom;
        return;
    }
    gInside = 1;                  /* the call itself is a _DragDispatch */
    err = InstallTrackingHandler(track_upp(), NULL, NULL);
    gInside = 0;
    /* THE ROW GOES DOWN WHATEVER HAPPENED, and before the early return
       below, because a refusal here is the finding this instrument was
       added to catch: handler_state and handler_err are single globals
       that the next application's success overwrites. */
    track_note(block, a5, (NowPeekI32)err);
    if (err != noErr) {
        block->handler_state = (NowPeekU32)kNowPeekDragObsHandlerRefused;
        block->handler_err = (NowPeekI32)err;
        return;
    }
    gTrackContexts[gTrackContextCount++] = a5;
    block->handler_installs++;
    block->handler_contexts = (NowPeekU32)gTrackContextCount;
    block->handler_state = (NowPeekU32)kNowPeekDragObsHandlerInstalled;
}

/* Give it back, and only from the context that took it. */
static void track_remove(NowPeekDragObserve *block, NowPeekU32 a5)
{
    int index = track_context_index(a5);
    int i;

    if (index < 0)
        return;
    gInside = 1;
    (void)RemoveTrackingHandler(track_upp(), NULL);
    gInside = 0;
    for (i = index; i + 1 < gTrackContextCount; ++i)
        gTrackContexts[i] = gTrackContexts[i + 1];
    gTrackContextCount--;
    block->handler_removes++;
    block->handler_contexts = (NowPeekU32)gTrackContextCount;
}

static void track_row(NowPeekDragObserve *block, NowPeekU32 message,
                      WindowRef window, DragRef drag, NowPeekU32 a5,
                      NowPeekU32 ticks)
{
    NowPeekDragObsTrack *row;
    Point dm_mouse, dm_pinned, lm_raw, lm_mouse;
    DragAttributes attrs = 0;
    OSErr err;
    NowPeekU32 index;

    if (block->track_count >= (NowPeekU32)kNowPeekDragObsTrackCapacity)
        block->track_dropped++;
    index = block->track_count % (NowPeekU32)kNowPeekDragObsTrackCapacity;
    row = &block->tracks[index];

    dm_mouse.h = 0; dm_mouse.v = 0;
    dm_pinned.h = 0; dm_pinned.v = 0;
    row->err = 0;
    err = GetDragMouse(drag, &dm_mouse, &dm_pinned);
    if (err != noErr && row->err == 0)
        row->err = (NowPeekI32)err;
    err = GetDragAttributes(drag, &attrs);
    if (err != noErr && row->err == 0)
        row->err = (NowPeekI32)err;
    lm_raw = LMGetRawMouseLocation();
    lm_mouse = LMGetMouseLocation();

    row->ticks = ticks;
    row->message = message;
    row->window = (NowPeekU32)window;
    row->a5 = a5;
    row->dm_mouse_h = (NowPeekI32)dm_mouse.h;
    row->dm_mouse_v = (NowPeekI32)dm_mouse.v;
    row->dm_pinned_h = (NowPeekI32)dm_pinned.h;
    row->dm_pinned_v = (NowPeekI32)dm_pinned.v;
    row->lm_raw_h = (NowPeekI32)lm_raw.h;
    row->lm_raw_v = (NowPeekI32)lm_raw.v;
    row->lm_mouse_h = (NowPeekI32)lm_mouse.h;
    row->lm_mouse_v = (NowPeekI32)lm_mouse.v;
    row->attributes = (NowPeekU32)attrs;
    block->track_count++;         /* bumped LAST, as the ring rule needs */
}

static pascal OSErr now_dragobs_tracking(DragTrackingMessage message,
                                         WindowRef theWindow,
                                         void *refCon, DragRef theDrag)
{
    NowPeekDragObserve *block = shim_block();
    NowPeekU32 ticks;
    NowPeekU32 a5;

    (void)refCon;
    if (block == NULL)
        return noErr;
    if (gInside) {
        block->handler_reentries++;
        return noErr;
    }
    ticks = (NowPeekU32)LMGetTicks();
    a5 = (NowPeekU32)LMGetCurrentA5();
    block->handler_calls++;

    switch (message) {
    case kDragTrackingEnterHandler:
        block->handler_enter_handler++;
        block->handler_begin_seq++;          /* odd: mid-write */
        block->handler_a5 = a5;
        block->handler_drag_ref = (NowPeekU32)theDrag;
        block->handler_first_ticks = ticks;
        block->track_count = 0;
        block->track_dropped = 0;
        gInside = 1;
        read_identity_into(block, theDrag, &block->hitem_count,
                           &block->hitem_status, &block->hitem_err,
                           &block->hfile_type, &block->hfile_creator,
                           &block->hfile_vrefnum, &block->hfile_parid,
                           block->hfile_name);
        gInside = 0;
        block->handler_begin_seq++;          /* even: whole */
        /* AND NOW THE HALF THAT MAKES IT USEFUL IN TIME.
           ------------------------------------------------------------
           Everything above puts the identity in a cell, and the cell is
           read by the PowerPC application - which gets no task time at
           all until this drag loop ends. Measured 2026-08-16: the
           application published this same identity 462 ticks after the
           drag began and 14 ticks after it ENDED, which is after the
           crossing it was needed for. So the resident says it itself,
           here, over its own connection, while the button is still
           down.

           SENT AFTER THE COMMIT WORD, deliberately: the application's
           drain reads the cell on the strength of an even
           `handler_begin_seq`, and a send that preceded it would be a
           host holding a fact the machine's own table does not yet
           admit to.

           ONLY AN HFS FIRST ITEM. A promise or a text drag names no
           file this side could serve and the frame must not invent one -
           the same gate the application's drain applies, applied here
           for the same reason.

           NO EPOCH, NO FRAME. A drag seen while nothing is armed for
           Continuity is a person using their own Macintosh, not a
           consent, and the host has nothing to bind it to. */
        if (block->hitem_status == (NowPeekU32)kNowPeekDragObsItemHFS) {
            NowPeekContinuityCell *cell = dragobs_cell(gTable);

            if (cell != NULL && cell->epoch != 0) {
                (void)now_liveness_net_send_drag(
                    gTable, cell->epoch, block->handler_begin_seq, ticks,
                    block->hfile_type, block->hfile_creator,
                    block->hfile_vrefnum, block->hfile_parid,
                    block->hfile_name);
            }
        }
        break;
    case kDragTrackingEnterWindow:
        block->handler_enter_window++;
        break;
    case kDragTrackingInWindow:
        block->handler_in_window++;
        break;
    case kDragTrackingLeaveWindow:
        block->handler_leave_window++;
        break;
    case kDragTrackingLeaveHandler:
        block->handler_leave_handler++;
        break;
    default:
        break;
    }
    /* Every message gets a row, including the two handler-level ones:
       the targeting question is about the SEQUENCE, and a ring that
       recorded only the window messages could not show a drag that
       entered the handler and never named a window at all. */
    gInside = 1;
    track_row(block, (NowPeekU32)message, theWindow, theDrag, a5, ticks);
    gInside = 0;
    /* noErr, always. A tracking handler's result is consulted. */
    return noErr;
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
    /* V17, and it is BEFORE the gate on purpose - that is the whole
       instrument. Counted for every application that reaches here,
       whether or not anything is armed. */
    pump_note(&cell->drag_observe, (NowPeekU32)LMGetCurrentA5(),
              continuity_armed
                  || (request & (NowPeekU32)kNowPeekTableCapAct) != 0);
    if (!continuity_armed
            && !(request & (NowPeekU32)kNowPeekTableCapAct)) {
        /* THE DISARM HALF, and it is the reason this function does not
           simply return when it has nothing to do. A registration is
           per-application, so it can only be given back from the
           application that took it - and this pass is the only time we
           are ever inside that application again. A handler left behind
           after the arm ends is worse than a leaked trap patch: the Drag
           Manager would go on calling into a plane that has been told to
           stand down. */
        if (gTrackContextCount != 0)
            track_remove(&cell->drag_observe,
                         (NowPeekU32)LMGetCurrentA5());
        return;
    }
    gTable = table;
    dragobs_install(&cell->drag_observe);
    dragobs_selftest(&cell->drag_observe);
    /* The registration route, in whatever application is pumping. The
       Finder registers itself the first time it pumps while armed. */
    track_install(&cell->drag_observe, (NowPeekU32)LMGetCurrentA5());
}

/* ---- reading a drag ---------------------------------------------------
 *
 * Every function below runs with gInside already set by its caller, so
 * the Drag Manager calls it makes chain straight through the shim. */

static void read_identity_into(NowPeekDragObserve *block, DragRef drag,
                               NowPeekU32 *out_count, NowPeekU32 *out_status,
                               NowPeekI32 *out_err, NowPeekU32 *out_type,
                               NowPeekU32 *out_creator, NowPeekI32 *out_vref,
                               NowPeekU32 *out_parid, unsigned char *out_name)
{
    (void)block;
    HFSFlavor flavor;
    DragItemRef item = 0;
    UInt16 count = 0;
    Size size = 0;
    OSErr err;
    int i;

    *out_status = (NowPeekU32)kNowPeekDragObsItemUnknown;
    *out_err = 0;
    *out_count = 0;
    *out_type = 0;
    *out_creator = 0;
    *out_vref = 0;
    *out_parid = 0;
    for (i = 0; i < 64; ++i)
        out_name[i] = 0;

    err = CountDragItems(drag, &count);
    if (err != noErr) {
        *out_status = (NowPeekU32)kNowPeekDragObsItemError;
        *out_err = (NowPeekI32)err;
        return;
    }
    /* The honest count, whatever it is. An over-count is reported as the
       number it is and never collapsed into the first item's identity:
       `item_status` describes ITEM ONE and says so in the contract. */
    *out_count = (NowPeekU32)count;
    if (count == 0) {
        *out_status = (NowPeekU32)kNowPeekDragObsItemNoHFS;
        return;
    }
    err = GetDragItemReferenceNumber(drag, 1, &item);
    if (err != noErr) {
        *out_status = (NowPeekU32)kNowPeekDragObsItemError;
        *out_err = (NowPeekI32)err;
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
            *out_status = (NowPeekU32)kNowPeekDragObsItemPromise;
            return;
        }
        *out_status = (NowPeekU32)kNowPeekDragObsItemNoHFS;
        *out_err = (NowPeekI32)err;
        return;
    }
    if (size < (Size)sizeof(flavor)) {
        /* Short read: something answered, but not with an HFSFlavor. */
        *out_status = (NowPeekU32)kNowPeekDragObsItemError;
        *out_err = (NowPeekI32)size;
        return;
    }
    *out_status = (NowPeekU32)kNowPeekDragObsItemHFS;
    *out_type = (NowPeekU32)flavor.fileType;
    *out_creator = (NowPeekU32)flavor.fileCreator;
    *out_vref = (NowPeekI32)flavor.fileSpec.vRefNum;
    *out_parid = (NowPeekU32)flavor.fileSpec.parID;
    /* Copied by value into fixed width. A pointer into a foreign heap
       would be read after that heap may be gone - the same rule
       `guest_name` follows in the same table. Byte 0 is the Pascal
       length, so the copy is bounded by both it and the field. */
    {
        int len = (int)flavor.fileSpec.name[0];

        if (len > 62)
            len = 62;
        out_name[0] = (unsigned char)len;
        for (i = 0; i < len; ++i)
            out_name[i + 1] = flavor.fileSpec.name[i + 1];
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
    read_identity_into(block, gLiveDrag, &block->item_count,
                       &block->item_status, &block->item_err,
                       &block->file_type, &block->file_creator,
                       &block->file_vrefnum, &block->file_parid,
                       block->file_name);
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
