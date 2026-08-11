/*
 * rig_init.c - CursorRig, a 68K INIT that drives the pointer from an
 * interrupt so a spike can measure how stale it gets.
 *
 * THIS IS A RIG. It writes the mouse position from a Time Manager task
 * and clicks at raw screen points with no idea what is under them. That
 * is correct for a measurement and would be a regression in a product:
 * clicking a point nobody resolved is exactly the inference a real act
 * plane refuses to make. Nothing here is a shipping path.
 *
 * Why an interrupt-level task at all: classic Mac OS is cooperatively
 * multitasked, and while another application sits in a tracking loop
 * (DragGrayRgn, TrackControl, a menu) calling StillDown/GetMouse, YOUR
 * application does not run. A 1.1 second drag was instrumented at 67
 * ticks and ONE yield. So an application cannot be the thing that moves
 * a pointer smoothly, and a Time Manager task is the cheapest thing
 * that reliably executes inside somebody else's loop.
 *
 * Three things this file is careful about, each of them a defect
 * somebody has already paid for here:
 *
 *   - The Time Manager task is entered through rig_tm.S because the
 *     task record arrives in A1 and a C function would read the stack.
 *   - It is INSTALLED at boot and never PRIMED there: a task that fires
 *     during startup writes into a machine that is still assembling
 *     itself. The first prime comes from the jGNE filter, which by
 *     definition means somebody reached an event loop.
 *   - The picture and the position are separate. The low-memory writes
 *     are what tracking loops and GetMouse read; the drawn sprite on
 *     Mac OS 9 does not follow them, and is settled with a HideCursor /
 *     ShowCursor pair at event-loop time. So a placement records a DEBT
 *     and the sample carries both timestamps - which is the whole
 *     reason this rig can tell "the pointer is late" from "the picture
 *     is late", two failures that look identical to a person watching.
 *
 * Exclusive by declaration: it refuses to install beside another
 * CursorRig or beside the NOW Extension. Two residents patching the
 * same machine is not a hypothetical hazard - the second one's saved
 * "previous" becomes the first one's shim, and removing either orphans
 * a live chain.
 */

#include <Events.h>
#include <Gestalt.h>
#include <LowMem.h>
#include <MacMemory.h>
#include <OSUtils.h>
#include <Quickdraw.h>
#include <Resources.h>
#include <Retro68Runtime.h>
#include <Timer.h>
#include <Traps.h>

#include "cursor_rig.h"

/* 16 ms is one tick, which is the resolution of the clock this rig
   records with and the rate the OS itself redraws a pointer at. Asking
   for less would measure the Time Manager rather than the cursor. */
#define kRigTimerPeriodMs 16

#define kNowExtGestaltSelector 0x4E576578L      /* 'NWex' */

/* Generated at build time (tools/gen_build_id.py) from a hash of this
   resident's own sources. It is the answer to "is the extension running
   here the one I just staged?", which no other field in the table can
   give: a stale INIT has the right name, the right Gestalt selector and
   the right magic number. */
extern const RigU32 kRigBuildId;

/* Resident state. The flat blob is relocated to a fixed system-heap
   address (sysHeap + locked + detached), so these absolute pointers stay
   valid from any later context - which is why Retro68FreeGlobals() is
   never called. */
static RigTable *gTable;
static TMTask    gTask;
static int       gTimerStarted;
static int       gRedrawOwed;
static void     *gCursorDevice;
static int       gDeviceProbed;

/* Referenced from assembly, so plain globals with external linkage. */
GetNextEventFilterUPP gRigOldGNEFilter;
void *gRigOldGetMouse;
void *gRigOldStillDown;
void *gRigOldButton;

/* The traps a tracking loop calls, from the ONEWORDINLINE on each
   declaration in Events.h - read there, not recalled. All ToolTrap. */
#define kRigGetMouseTrap  0xA972
#define kRigStillDownTrap 0xA973
#define kRigButtonTrap    0xA974

extern void  rig_gne_filter(void);
extern void  rig_getmouse_patch(void);
extern void  rig_stilldown_patch(void);
extern void  rig_button_patch(void);
extern void  rig_tm_entry(void);
extern long rig_cursor_device_move_to(void *device, long absX, long absY);
extern long rig_cursor_next_device(void **device);

/* Low memory as a byte, through a volatile the optimiser cannot fold.
   A literal address looks to GCC's array-bounds pass like an object of
   known (tiny) size, so indexing it is diagnosed and -Werror stops the
   build. The bounds are real and simply not visible from C; routing the
   address through a volatile is the narrowest way to say so, and it is
   honest twice over, because low memory genuinely does change under us. */
static volatile unsigned char *lowmem_byte(unsigned long addr)
{
    volatile unsigned long opaque = addr;

    return (volatile unsigned char *)opaque;
}

#define kCrsrNew     0x08CEUL
#define kCrsrCouple  0x08CFUL
#define kCrsrObscure 0x08D2UL

/* The Cursor Device Manager, asked once and only after the machine is
   up: at INIT time it may not be there to answer. Absent, the rig still
   places the pointer - the position writes are the half that makes a
   tracking loop agree - and says so through caps rather than pretending. */
static void probe_cursor_device(void)
{
    void *device = NULL;

    UniversalProcPtr here;
    UniversalProcPtr unimpl;

    gDeviceProbed = 1;
    /* A trap word whose entry equals _Unimplemented's is a trap the ROM
       does not serve, and ISSUING it would run whatever _Unimplemented
       does - which on a Macintosh is not a polite error return. The
       whole trap word is passed; NGetTrapAddress masks it. */
    here = NGetTrapAddress(0xAADB, ToolTrap);
    unimpl = NGetTrapAddress(_Unimplemented, ToolTrap);
    if (here == NULL || here == unimpl) {
        return;
    }
    if (rig_cursor_next_device(&device) != 0L || device == NULL) {
        return;
    }
    gCursorDevice = device;
    gTable->caps |= kRigCapDevice;
}

/* Put the pointer where the command says. Runs at interrupt time: low
   memory, one trap through the Cursor Device Manager (the call a mouse
   driver's own interrupt handler makes sixty times a second), and no
   QuickDraw - the picture is owed, not drawn. */
static void rig_place(RigTable *t, const RigMailbox *box)
{
    Point pt;
    RigU32 route = kRigRouteLowMem;

    pt.h = box->h;
    pt.v = box->v;
    LMSetMouseTemp(pt);
    LMSetRawMouseLocation(pt);
    LMSetMouseLocation(pt);

    /* CrsrObscure must be cleared because we ARE the mouse moving.
       ObscureCursor is what every text application calls on a keystroke
       - hide the arrow until the mouse moves - and the pointing
       device's driver clears it on its next report. Without this the
       rig would draw faithfully into an invisible cursor: every counter
       climbing, zero pixels changed, indistinguishable from not
       working. */
    *lowmem_byte(kCrsrObscure) = 0;
    *lowmem_byte(kCrsrNew) = *lowmem_byte(kCrsrCouple);

    if (gCursorDevice != NULL) {
        rig_cursor_device_move_to(gCursorDevice, (long)box->h, (long)box->v);
        route = kRigRouteDevice;
    }

    if (t->caps & kRigCapRedraw) {
        gRedrawOwed = 1;
        route = kRigRouteRedrawOwed;
    }
    t->place_route = route;
}

/* A click, the rig way: the button state plus one posted event whose
   evtQWhere is stamped explicitly. PPostEvent hands back the queue
   element so the target point survives the mouse-VBL race - the mouse
   task can overwrite MouseLocation between our write and the front
   application dequeuing (finding input-injection-postevent-not-journal,
   proven on this emulator and on metal). */
static void rig_click(const RigMailbox *box)
{
    EvQElPtr qel = NULL;
    short kind = box->arg ? mouseDown : mouseUp;

    LMSetMouseButtonState(box->arg ? 0x00 : 0x80);
    if (PPostEvent(kind, 0, &qel) == noErr && qel != NULL) {
        qel->evtQWhere.h = box->h;
        qel->evtQWhere.v = box->v;
    }
}

/* The Time Manager task. Entered from rig_tm.S with the record as an
   ordinary argument. It fires whether or not a run is armed, because
   the tick count itself is evidence: a task that stopped firing and a
   task that had nothing to do are different failures, and only the
   counter separates them. */
void rig_tm_tick(TMTaskPtr task);
void rig_tm_tick(TMTaskPtr task)
{
    RigTable *t = gTable;
    RigMailbox box;

    if (t != NULL) {
        t->timer_ticks++;
        if (t->armed && t->mode == kRigModeTimer && rig_mailbox_take(t, &box)) {
            rig_place(t, &box);
            if (box.op == kRigOpClick) {
                rig_click(&box);
            }
            rig_apply_record(t, &box, (RigU32)LMGetTicks());
        }
    }
    /* Re-prime from inside the task, which is what makes it periodic.
       A task that forgets this fires exactly once and looks, from every
       counter, like a task that was never installed. */
    PrimeTime((QElemPtr)task, kRigTimerPeriodMs);
}

/* Settle the picture, if one is owed. Called from the jGNE filter and
   from the three tracking traps - both are TASK time in some
   application's context, which is what QuickDraw requires and what the
   Time Manager task can never be.

   HideCursor erases the sprite from wherever it really is and
   ShowCursor draws it at the current mouse position, which is the one
   the writer already set. The pair is a nesting counter rather than a
   cursor setter, so the SHAPE is preserved and an application's own
   SetCursor still decides what is drawn. */
void rig_settle_picture(void);
void rig_settle_picture(void)
{
    RigTable *t = gTable;

    if (t == NULL || !gRedrawOwed) {
        return;
    }
    gRedrawOwed = 0;
    HideCursor();
    ShowCursor();
    rig_redraw_record(t, (RigU32)LMGetTicks());
}

/* Somebody reached an event loop. Three things happen here and nowhere
   else, because this is the only moment the rig has a real context. */
void rig_gne_pass(void);
void rig_gne_pass(void)
{
    RigTable *t = gTable;

    if (t == NULL) {
        return;
    }
    t->gne_passes++;

    if (!gDeviceProbed) {
        probe_cursor_device();
    }

    /* The first prime. Deliberately not at boot: a periodic task that
       starts while the machine is still assembling itself writes into
       something that is not finished. */
    if (!gTimerStarted) {
        gTimerStarted = 1;
        PrimeTime((QElemPtr)&gTask, kRigTimerPeriodMs);
        return;
    }

    /* Settle the picture. HideCursor erases the sprite from wherever it
       really is and ShowCursor draws it at the current mouse position,
       which is the one the writer just set; the pair is a nesting
       counter rather than a cursor setter, so an application's own
       SetCursor still decides the SHAPE. The debt is settled whether or
       not a run is armed - a picture that disagrees with the machine is
       wrong either way. */
    rig_settle_picture();
}

static pascal OSErr rig_gestalt(OSType selector, long *response)
{
    (void)selector;
    *response = (long)gTable;
    return noErr;
}

void _start(void)
{
    Handle self;
    SelectorFunctionUPP gestalt_upp;
    RigTable *table;
    long response;
    int conflict;

    RETRO68_RELOCATE();
    Retro68CallConstructors();

    self = Get1Resource('INIT', 128);
    if (self == NULL) {
        return;
    }
    DetachResource(self);

    /* Exclusive by declaration, and the check is before anything is
       allocated or hooked. A second CursorRig would chain jGNE behind
       the first and both would drive the pointer; the NOW Extension
       patches traps and moves the same cursor, so a measurement taken
       beside it would be measuring both of us. */
    if (Gestalt((OSType)kRigGestaltSelector, &response) == noErr) {
        return;                         /* a CursorRig is already here */
    }
    conflict = (Gestalt((OSType)kNowExtGestaltSelector, &response) == noErr);

    table = (RigTable *)NewPtrSysClear((Size)sizeof(RigTable));
    if (table == NULL) {
        return;                         /* no heap: degrade to absent */
    }
    table->format = kRigTableFormat;
    table->length = (RigU32)sizeof(RigTable);
    table->ring_cap = kRigRingCap;
    /* A conflict publishes the table and NOTHING else: no capabilities,
       no Time Manager task, no jGNE filter. The table exists only so
       the host is told WHY the pointer is not moving - silence here
       reads exactly like an extension that was never staged, and the
       two have different cures. */
    table->refused = conflict ? kRigRefusedConflict : kRigRefusedNone;
    table->caps = conflict ? 0 : (kRigCapTimer | kRigCapRedraw);
    table->build_id = kRigBuildId;
    table->run_start_ticks = (RigU32)LMGetTicks();
    rig_ring_reset(table);
    /* Magic last, so a reader that somehow finds the address early sees
       a table only once it is fully formed. */
    table->magic = kRigTableMagic;
    gTable = table;

    gestalt_upp = NewSelectorFunctionUPP(rig_gestalt);
    if (NewGestalt((OSType)kRigGestaltSelector, gestalt_upp) != noErr) {
        if (gestalt_upp != NULL) {
            DisposeSelectorFunctionUPP(gestalt_upp);
        }
        DisposePtr((Ptr)table);
        gTable = NULL;
        return;
    }

    if (conflict) {
        return;                         /* published, inert, and honest */
    }

    /* Install the task; do NOT prime it. See rig_gne_pass. */
    gTask.tmAddr = (TimerUPP)rig_tm_entry;
    gTask.tmWakeUp = 0;
    gTask.tmReserved = 0;
    InsTime((QElemPtr)&gTask);

    /* Callbacks last, per the INIT failure-atomicity rule: everything
       above can unwind, and nothing below can. */
    gRigOldGNEFilter = LMGetGNEFilter();
    LMSetGNEFilter((GetNextEventFilterUPP)rig_gne_filter);

    /* The tracking traps. These are what make the PICTURE follow during
       somebody else's drag - see rig_patch.S. Each is installed only if
       its incumbent could be read, and none is ever removed: a patch
       that vanishes while a caller is inside it is a jump into freed
       code. */
    gRigOldGetMouse = (void *)NGetTrapAddress(kRigGetMouseTrap, ToolTrap);
    gRigOldStillDown = (void *)NGetTrapAddress(kRigStillDownTrap, ToolTrap);
    gRigOldButton = (void *)NGetTrapAddress(kRigButtonTrap, ToolTrap);
    if (gRigOldGetMouse != NULL && gRigOldStillDown != NULL
        && gRigOldButton != NULL) {
        NSetTrapAddress((UniversalProcPtr)rig_getmouse_patch,
                        kRigGetMouseTrap, ToolTrap);
        NSetTrapAddress((UniversalProcPtr)rig_stilldown_patch,
                        kRigStillDownTrap, ToolTrap);
        NSetTrapAddress((UniversalProcPtr)rig_button_patch,
                        kRigButtonTrap, ToolTrap);
        table->caps |= kRigCapTrackingPatch;
    }
}
