/*
 * now_ext_drag.c - P7, the drag vehicle: a mouse button that stays down.
 *
 * WHY THIS IS A TIME MANAGER TASK AND NOT MORE OF P4
 * --------------------------------------------------
 * P4 (now_ext_act.c) serves every act from the jGNE filter, which runs
 * inside the application's own GetNextEvent. That is the right place for
 * everything P4 does and it is the wrong place - in fact an impossible
 * place - for a drag.
 *
 * The moment the button goes down, the application enters its own
 * tracking loop. The Finder's is `DragGrayRgn`, reading `StillDown`,
 * `GetMouse` and `WaitMouseUp`; a scroll bar's is `TrackControl`. None of
 * them calls GetNextEvent. So from the press until the release, THE jGNE
 * FILTER IS NEVER ENTERED, and any design that delivers motion or a
 * release through it delivers neither.
 *
 * A Time Manager task fires regardless of who is being scheduled - the
 * same argument P6's liveness vehicle makes, for the same reason - so it
 * is the only vehicle in this component that can act while an
 * application is inside a loop.
 *
 * WHAT IT ACTUALLY DOES
 * ---------------------
 * Everything those tracking loops read is a mouse low-memory global:
 *
 *   MBState (0x0172)          - Button(), and therefore StillDown()
 *   MouseLocation (0x0830)    - GetMouse()
 *   RawMouseLocation (0x082C) - the cursor's own position
 *   MTemp (0x0828)            - the cursor VBL's staging point
 *
 * So the whole vehicle is: write those four, and stop writing them when
 * the deadline says so. There is no trap patch here at all, which is why
 * this plane has a much smaller blast radius than P4's six.
 *
 * THE DEAD-MAN, AND WHY IT IS HERE RATHER THAN ON THE HOST
 * --------------------------------------------------------
 * A guest left with the button down sits in that tracking loop forever,
 * and the host cannot rescue it: the host's only channel into the guest
 * is the cell the wedged application has stopped reading. So the release
 * cannot be anything the host is trusted to send. It is a deadline this
 * task enforces, and it fires whether or not anybody asks - including
 * when the host process was killed between the press and the release,
 * which is the case the whole design is shaped around.
 *
 * The DECISION lives in now_drag_logic.c, where the host cc compiles it
 * and `scripts/test-native` can watch it fail. This file is the vehicle
 * and does not decide anything.
 *
 * TWO HALVES OF A RELEASE, AND WHY THEY ARE SEPARATE
 * ---------------------------------------------------
 * Writing MBState up is what every tracking loop actually reads, and it
 * happens HERE, at interrupt time, where nothing can refuse it. Queueing
 * a mouseUp EVENT needs PPostEvent and the target's own context, so it
 * is left owed (`pending_mouseup`) and the jGNE pass posts it on its next
 * entry - which arrives as soon as the tracking loop, now seeing the
 * button up, hands the application back to GetNextEvent.
 *
 * The split is deliberate and the ordering is the safety property: the
 * part that must never fail runs where it cannot, and the part that
 * needs a context waits for one. An implementation that posted the event
 * from here would put an Event Manager call at interrupt time on the
 * critical path of the one rule that must not have a critical path.
 */
#include <MacTypes.h>
#include <Events.h>
#include <LowMem.h>
#include <Timer.h>

#include "peek_table.h"
#include "now_drag_logic.h"

/* THE CURSOR IS NOT THIS FILE'S JOB ANY MORE.
   It was: this vehicle wrote MTemp, RawMouse and MouseLocation and then
   copied CrsrCouple into CrsrNew, which is Inside Macintosh's recipe for
   asking the cursor VBL task to redraw. The recipe drives everything the
   Toolbox READS and does not move the picture - measured on 2026-08-07,
   five moves and five screendump pairs, zero pixels each. The reason is
   not this plane's and the cure is not either: on Mac OS 8/9 the Cursor
   Device Manager owns the sprite. So placement moved out to P8
   (now_ext_cursor.c), which owns both halves - the low-memory writes a
   tracking loop reads AND the manager call that redraws - and this file
   asks for a point rather than spelling how to get there.

   The two addresses went with it. Two files spelling 0x08CE is exactly
   how a pair drifts, and the one that was left behind would have been
   the one still being read. */
extern int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, unsigned flags);

typedef struct {
    TMTask task;                /* first: the Time Manager owns this */
    NowPeekTable *table;
} DragTask;

static DragTask gDragTask;
static Boolean gDragInstalled = false;

/* The assembly shim (now_ext_drag_tm.S) the Time Manager actually calls. */
extern void now_ext_drag_tm_entry(void);

void now_ext_drag_tick(TMTaskPtr task);
int now_ext_drag_press(NowPeekTable *table, NowPeekU32 session,
                       NowPeekU32 target_a5, NowPeekI32 h, NowPeekI32 v,
                       NowPeekU32 idle_asked, NowPeekU32 cap_asked);
void now_ext_drag_boot(NowPeekTable *table);
NowPeekDragCell *now_ext_drag_cell(NowPeekTable *table);
void now_ext_drag_abandon(NowPeekTable *table);

/* The drag cell, or NULL when this table is too short to hold one. The
   length check is the accretive rule's other half: an application built
   against P7 talking to a resident that predates it must find nothing
   here rather than write past the end of a system-heap block sized by a
   different binary. */
NowPeekDragCell *now_ext_drag_cell(NowPeekTable *table)
{
    if (table == NULL) {
        return NULL;
    }
    if (table->magic != (NowPeekU32)kNowPeekTableMagic) {
        return NULL;
    }
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, drag)
                                     + sizeof(NowPeekDragCell))) {
        return NULL;
    }
    if (table->drag_format != (NowPeekU32)kNowPeekDragFormatV1) {
        return NULL;
    }
    return &table->drag;
}

/* Put the pointer somewhere, and make the machine agree that it is
   there. P8 does both halves; `owned` is 1 because THIS PLANE IS THE
   THING DRIVING THE POINTER for the length of the gesture, so P8's
   "somebody else is moving it, leave the sprite alone" courtesy must not
   apply - mid-drag it would strand the sprite halfway through a gesture
   the application is already tracking. */
static void drag_place(NowPeekI32 h, NowPeekI32 v)
{
    (void)now_ext_cursor_place(h, v,
                               kNowCursorPlaceOwned
                                   | kNowCursorPlaceInterrupt);
}

/* The two writes that are the button, and nothing else. Separated from
   everything above so that the one line whose failure wedges a machine
   is a line you can point at.

   MBState is 0x00 for DOWN and 0x80 for UP - the byte's high bit, not a
   boolean - which is the same encoding act_post_click uses and the same
   one the ADB driver writes. */
static void drag_button(int down)
{
    LMSetMouseButtonState(down ? 0x00 : 0x80);
}

/* Begin a gesture. Called from the jGNE act pass, in the target
   application's own context, having already passed that plane's identity
   and lease checks - which is why there are none here.

   Returns 0 when there is no vehicle or a drag is already held; the
   caller turns that into kNowPeekActErrDragNoVehicle / DragBusy. */
int now_ext_drag_press(NowPeekTable *table, NowPeekU32 session,
                       NowPeekU32 target_a5, NowPeekI32 h, NowPeekI32 v,
                       NowPeekU32 idle_asked, NowPeekU32 cap_asked)
{
    NowPeekDragCell *cell = now_ext_drag_cell(table);
    unsigned long ticks;

    if (cell == NULL || !gDragInstalled) {
        return 0;
    }
    ticks = (unsigned long)LMGetTicks();
    if (!now_drag_begin(cell, session, target_a5, h, v, (NowPeekU32)ticks,
                        idle_asked, cap_asked)) {
        return 0;
    }

    /* Order matters and is the reverse of the release's. Put the pointer
       where the press is going FIRST, so that whatever reads the button
       an instant later reads a location that already agrees with it. A
       button that goes down before the pointer arrives is a click at the
       old place. */
    drag_place(h, v);
    drag_button(1);

    /* Prime only now. A task primed at boot and re-priming forever would
       be a second 60-times-a-second interrupt on a machine that may never
       drag anything, and P6 already argued for one of those on grounds
       this task cannot borrow. */
    PrimeTime((QElemPtr)&gDragTask.task, (long)kNowPeekDragTickMs);
    return 1;
}

/* Called from the shim. INTERRUPT TIME: nothing here may allocate,
   block, move memory, or call anything that could. Every Toolbox call
   below is a low-memory accessor, which is a move.b or move.l to an
   absolute address and nothing more. */
void now_ext_drag_tick(TMTaskPtr task)
{
    DragTask *self = (DragTask *)task;
    NowPeekDragCell *cell;
    NowPeekU32 ticks;
    int action;

    if (self == NULL) {
        return;                       /* nothing to re-prime, either */
    }
    /* The magic check is not defensive habit - see now_liveness.c, where
       a wrong task-record pointer wrote into a booting Finder's memory
       every five seconds. A wrong pointer must cost a silent tick. */
    cell = now_ext_drag_cell(self->table);
    if (cell == NULL) {
        return;                       /* and, deliberately, no re-prime */
    }

    ticks = (NowPeekU32)LMGetTicks();
    action = now_drag_tick(cell, ticks);

    switch (action) {
    case kNowDragTickRelease:
        /* THE LINE. Whatever else is true, after this the machine is not
           holding the button, and it runs before anything that could
           fail. Note there is no re-prime below it: a released session
           stops costing interrupts immediately. */
        drag_button(0);
        drag_place(cell->at_h, cell->at_v);
        return;
    case kNowDragTickMove:
        drag_place(cell->at_h, cell->at_v);
        break;
    case kNowDragTickNothing:
    default:
        /* Still held, nothing new asked. The button state is REASSERTED
           anyway, every tick, and that is not redundant: the emulated
           ADB mouse VBL writes the same byte, and a stray host-side
           mouse event between our ticks would otherwise lift the button
           halfway through a gesture. Cheap insurance in the one place
           that can afford it. */
        drag_button(1);
        break;
    }
    /* Re-primed at the end rather than the start, so a long tick can
       never overlap itself - the same rule the liveness task follows. */
    PrimeTime((QElemPtr)&gDragTask.task, (long)kNowPeekDragTickMs);
}

/* The plane is being disarmed, or the writer lease changed under a live
   session. The button goes up - that is not negotiable - but the gesture
   is recorded as lost rather than completed, so nothing downstream can
   read it as a drag that finished.

   Called from the jGNE pass, NOT from interrupt time, which is why it
   may also settle the owed event immediately. */
void now_ext_drag_abandon(NowPeekTable *table)
{
    NowPeekDragCell *cell = now_ext_drag_cell(table);

    if (cell == NULL) {
        return;
    }
    if (now_drag_abandon(cell, (NowPeekU32)LMGetTicks())
            == kNowDragTickRelease) {
        drag_button(0);
    }
}

/* Install the task once, at boot, WITHOUT priming it. InsTime is the
   allocation-shaped half of the Time Manager's API and belongs at boot
   for the reason now_liveness.c gives about PBOpen: a call that can move
   memory must not be reachable from the hook. Priming is what a press
   does, and it is cheap.

   The capability bit is published only if the install succeeded, so an
   application never arms a vehicle that cannot fire - which is what
   kNowPeekActErrDragNoVehicle exists to report. */
void now_ext_drag_boot(NowPeekTable *table)
{
    if (table == NULL || gDragInstalled) {
        return;
    }
    gDragTask.table = table;
    gDragTask.task.tmAddr = (TimerUPP)now_ext_drag_tm_entry;
    gDragTask.task.tmWakeUp = 0;
    gDragTask.task.tmReserved = 0;
    InsTime((QElemPtr)&gDragTask.task);
    gDragInstalled = true;

    table->drag_format = (NowPeekU32)kNowPeekDragFormatV1;
    table->drag.state = (NowPeekU32)kNowPeekDragStateIdle;
    table->drag.button_down = 0;
    table->caps |= (NowPeekU32)kNowPeekTableCapDrag;
}
