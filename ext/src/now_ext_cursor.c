/*
 * now_ext_cursor.c - P8, the drawn cursor follows what we act on.
 *
 * WHAT WAS WRONG, AND HOW IT WAS ESTABLISHED
 * -------------------------------------------
 * P4 and P7 both move the pointer the documented Inside Macintosh way:
 * write MTemp, RawMouse and MouseLocation, then copy CrsrCouple into
 * CrsrNew to ask the cursor VBL task for a redraw. Everything the
 * Toolbox READS follows those writes perfectly - GetMouse, StillDown,
 * the whole tracking-loop surface - and the SPRITE never moves. Five
 * resident moves, five screendump pairs, zero pixels changed each time
 * (2026-08-07, tools/local-cursor-sprite.py, emulated mac99/OS 9.1).
 *
 * The obvious suspect was the rig: an emulated pointing device reporting
 * over the top of our writes. IT IS NOT, and that matters more than the
 * fix, because it means metal is not a different case. Read from OUTSIDE
 * the guest through QMP, with nothing touching the host pointer, all
 * three globals held our value unchanged for seconds. Nothing overwrites
 * them. And every precondition the documented recipe needs was met:
 * CrsrCouple was 0xff (coupled), CrsrState 0 (drawable), CrsrObscure 0,
 * CrsrBusy 0 - and CrsrNew read back 0x00, meaning our request had been
 * CONSUMED. The task ran. It just did not draw.
 *
 * What did move the sprite was the emulated device, and its trail says
 * why: after it, the Cursor Device Manager's own CursorData record held
 * FRACTIONAL coordinates (419.63, 333.25) and the changed pixels boxed
 * the old sprite and the new one together. Our writes reach that record
 * too - it followed every move, exactly, to the integer - so the manager
 * knows where the cursor is and simply is not the thing we asked to
 * redraw it. **On Mac OS 8/9 the Cursor Device Manager owns the sprite,
 * and the low-memory globals are downstream of it rather than upstream.**
 *
 * SO THIS FILE CALLS THE MANAGER. `CursorDeviceMoveTo` is the call a
 * mouse driver's own interrupt handler makes, sixty times a second, on
 * the device the manager hands out - which is why it is safe from the
 * drag Time Manager task, and why it is an absolute move with no
 * acceleration applied, which is what an act needs.
 *
 * THE LOW-MEMORY WRITES DID NOT GO AWAY, and that is deliberate. They
 * are what a tracking loop reads, they are what makes an act's click
 * land where the act says, and they work. This plane adds the redraw the
 * recipe was supposed to produce; it does not replace the half that was
 * never broken. When there is no manager, the old CrsrNew/CrsrCouple
 * line still runs, and is REPORTED as its own route so that a machine
 * quietly falling back is not read as a machine that worked.
 *
 * NOT FIGHTING A HUMAN
 * --------------------
 * A person at the machine moves the mouse; we move it somewhere else;
 * they move it back. That is a fight nobody wins and it is the one way
 * this plane could make a Macintosh worse to sit at. So before every
 * placement the resident asks whether the pointer is still where IT last
 * put it. If it is not, somebody else is driving, and for
 * kNowPeekCursorYieldTicks afterwards the sprite is left alone - the
 * position writes still happen, because an act must still land where it
 * says, and only the picture yields. Counted, in `yielded`, because a
 * courtesy nobody can observe is indistinguishable from a bug.
 *
 * A DRAG DOES NOT YIELD, and the asymmetry is the point. During a
 * gesture this plane IS the thing driving the pointer, so "the pointer
 * moved since we placed it" is not evidence of a person - it is the
 * acceleration of whatever else touched it, and yielding mid-drag would
 * leave the sprite stranded halfway through a gesture the application is
 * already tracking.
 */
#include <MacTypes.h>
#include <LowMem.h>
#include <Traps.h>
#include <Quickdraw.h>
#include <CursorDevices.h>

#include "peek_table.h"
#include "now_cursor_logic.h"

/* CrsrNew and CrsrCouple are past where this toolchain's LowMem.h stops
   (CrsrBusy, 0x08CD), and are reached through VOLATILE POINTER VARIABLES
   rather than cast constants. GCC folds `*(volatile UInt8 *)0x08CE` into
   a dereference of a known-tiny address and rejects it under
   -Werror=array-bounds as "likely at address zero" - correct about every
   C program except one running inside a Macintosh's low memory. Making
   the POINTER volatile means the compiler must load it before each use,
   which is the narrowest possible way to say "I mean this address".
   The addresses moved HERE from now_ext_drag.c, which no longer needs
   them: one plane owns the cursor now, and two files spelling the same
   two addresses is how the pair drifts. */
static volatile UInt8 *volatile gCrsrNew = (volatile UInt8 *)0x08CEUL;
static volatile UInt8 *volatile gCrsrCouple = (volatile UInt8 *)0x08CFUL;
/* CrsrObscure (0x08D2). Non-zero means an application called
   ObscureCursor - "hide the arrow, the person is typing" - and the
   cursor stays invisible UNTIL THE MOUSE MOVES. SimpleText does it on
   every keystroke; so does every text editor on this machine.

   We are the mouse moving. Clearing it is what the pointing device's own
   driver does on the next report, and without it P8 draws faithfully
   into an invisible cursor: watched 2026-08-07, `route` correct,
   `by_device` climbing, CrsrObscure 0x01 and zero pixels, which is
   indistinguishable from the plane not working at all. */
static volatile UInt8 *volatile gCrsrObscure = (volatile UInt8 *)0x08D2UL;

/* _CursorDeviceDispatch. Passed whole, the way now_content.c passes
   _QDExtensions; NGetTrapAddress masks it. */
#define kNowCursorDeviceTrap 0xAADB
#define kNowUnimplementedTrap 0xA89F

/* OSErr, from the assembly shims - see now_ext_cursor_cdm.S for why they
   cannot be C declarations with TWOWORDINLINE. */
extern long now_cdm_move_to(void *device, long absX, long absY);
extern long now_cdm_next_device(void **device);
/* The cursor task, through JCrsrTask. The manager moves the POSITION and
   this is what moves the PICTURE - see the shim's own header for how
   that was established, because the two look identical from inside the
   guest and the difference is 340 pixels of arrow. */
extern void now_cdm_crsr_task(void);

static NowPeekTable *gTable = NULL;
static CursorDevicePtr gDevice = NULL;
static Point gLastPlaced;
static unsigned long gForeignTicks = 0;
static Boolean gBooted = false;
/* A redraw this plane owes but could not perform where it was asked.
   The drawing route is QuickDraw and needs a real context; the drag
   vehicle runs at interrupt time and has none. So an interrupt-time
   placement records the debt and the next jGNE pass settles it - the
   same split P7 uses for its owed mouseUp, and for the same reason: the
   part that must not fail runs where it cannot, and the part that needs
   a context waits for one. */
static Boolean gRedrawOwed = false;

void now_ext_cursor_boot(NowPeekTable *table);
void now_ext_cursor_gne(NowPeekTable *table);
int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, unsigned flags);
NowPeekCursorCell *now_ext_cursor_cell(NowPeekTable *table);

/* The cursor cell, or NULL when this table is too short to hold one.
   The accretive rule's other half, and the same check the drag cell
   makes: an application built against P8 talking to a resident that
   predates it must find NOTHING here rather than write past the end of a
   system-heap block sized by a different binary. */
NowPeekCursorCell *now_ext_cursor_cell(NowPeekTable *table)
{
    if (table == NULL) {
        return NULL;
    }
    if (table->magic != (NowPeekU32)kNowPeekTableMagic) {
        return NULL;
    }
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, cursor)
                                     + sizeof(NowPeekCursorCell))) {
        return NULL;
    }
    if (table->cursor_format != (NowPeekU32)kNowPeekCursorFormatV1) {
        return NULL;
    }
    return &table->cursor;
}

/* Is the manager actually there? A trap word whose entry equals
   _Unimplemented's is a trap the ROM does not serve, and issuing it
   would run whatever _Unimplemented does - which on a Macintosh is not a
   polite error return. Every plane in this extension that reaches for a
   trap asks this first; the one that did not is not in the tree any
   more. */
static Boolean cursor_manager_present(void)
{
    UniversalProcPtr here =
        NGetTrapAddress(kNowCursorDeviceTrap, ToolTrap);
    UniversalProcPtr unimpl =
        NGetTrapAddress(kNowUnimplementedTrap, ToolTrap);
    return here != NULL && here != unimpl;
}

/* Put the pointer somewhere, and make the machine agree that it is
   there - both halves, in the order that matters.
 *
 * Returns the kNowPeekCursorRoute* that served it. `owned` is 1 when the
 * caller is holding the pointer for the duration of a gesture and must
 * never yield.
 *
 * INTERRUPT-SAFE: the drag task calls this every tick. Nothing here
 * allocates, blocks or moves memory - the low-memory accessors are
 * absolute moves, and CursorDeviceMoveTo is the call the ADB driver
 * makes from its own interrupt handler. */
int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, unsigned flags)
{
    NowPeekCursorCell *cell = now_ext_cursor_cell(gTable);
    Point pt;
    Point raw;
    unsigned long now;
    int route;

    pt.h = (short)h;
    pt.v = (short)v;

    /* WHO MOVED IT LAST, asked of the MANAGER rather than of RawMouse.
       It was RawMouse, and that was wrong in a way only driving found:
       between placements, with nothing holding the globals, RawMouse
       drifts back to the pointing device's own position - so every act
       after any device motion looked like a person had just moved the
       mouse, and the plane yielded forever. Four acts in a row reported
       `yielded` on a machine nobody was sitting at (2026-08-07).

       CursorData.where is the manager's own idea of the pointer. Only a
       real device moves it, and our own CursorDeviceMoveTo, whose value
       we already know. Asked BEFORE our writes, or the answer is always
       "us". */
    now = (unsigned long)LMGetTicks();
    if (gDevice != NULL && gDevice->whichCursor != NULL) {
        raw = gDevice->whichCursor->where;
    } else {
        raw = LMGetRawMouseLocation();
    }
    if (now_cursor_is_foreign((NowPeekI32)raw.h, (NowPeekI32)raw.v,
                              (NowPeekI32)gLastPlaced.h,
                              (NowPeekI32)gLastPlaced.v)) {
        gForeignTicks = now;
    }

    /* The position, always. An act must land where it says whether or
       not the picture is allowed to follow, and a tracking loop reads
       these and not the sprite. This is the half that was never broken
       and it is not conditional on anything. */
    LMSetMouseTemp(pt);
    LMSetRawMouseLocation(pt);
    LMSetMouseLocation(pt);
    gLastPlaced = pt;

    if (cell != NULL) {
        cell->seq++;                        /* odd: writing */
        cell->asked++;
        cell->at_h = h;
        cell->at_v = v;
    }

    if (now_cursor_should_yield((NowPeekU32)now, (NowPeekU32)gForeignTicks,
                                (flags & kNowCursorPlaceOwned) ? 1 : 0,
                                (NowPeekU32)kNowPeekCursorYieldTicks)) {
        route = kNowPeekCursorRouteYielded;
        if (cell != NULL) {
            cell->yielded++;
        }
    } else if (!(flags & kNowCursorPlaceInterrupt)) {
        /* THE ONLY ROUTE THAT MOVES THE PICTURE, and it is the crudest
           of the three.

           Everything upstream is already correct by the time we get
           here: the low-memory globals hold the point, and the Cursor
           Device Manager's own record does too - CursorDeviceMoveTo
           answers noErr and `where` reads back exactly right, verified
           from outside the guest. What none of that does is DRAW. On
           Mac OS 9 the blit happens somewhere in the pointing device's
           own interrupt path, and neither CrsrNew nor a direct call
           through JCrsrTask reaches it; both were tried and both left
           the arrow where the emulated device had last put it.

           HideCursor erases the sprite from wherever it is actually
           drawn; ShowCursor draws it at the current mouse position,
           which is the one we just wrote. The SHAPE is preserved -
           this pair is a nesting counter, not a cursor setter - so an
           application's own SetCursor still decides what is drawn.

           It needs a real context: HideCursor and ShowCursor are
           QuickDraw and are not interrupt-safe. The act plane has one,
           because it runs inside the target application's jGNE filter.
           The drag vehicle does not, which is why the flag exists and
           why a drag still reports `device` and is still invisible. */
        (void)now_cdm_move_to(gDevice, (long)h, (long)v);
        *gCrsrObscure = 0;
        HideCursor();
        ShowCursor();
        gRedrawOwed = false;
        route = kNowPeekCursorRouteQuickDraw;
        if (cell != NULL) {
            cell->by_device++;
        }
    } else if (gDevice != NULL) {
        long err = now_cdm_move_to(gDevice, (long)h, (long)v);
        if (err == 0) {
            /* State, then picture, and BOTH are required. The manager
               call alone leaves CursorData holding the new point with
               the arrow still drawn at the old one; the task alone would
               redraw from a position the manager does not agree with.
               CrsrNew is set first because the task is what consumes
               it. */
            *gCrsrNew = *gCrsrCouple;
            now_cdm_crsr_task();
            /* Neither of those draws - see the QuickDraw branch above.
               The debt is what makes an interrupt-time placement visible
               at all, at the next moment there is a context. */
            gRedrawOwed = true;
            route = kNowPeekCursorRouteDevice;
            if (cell != NULL) {
                cell->by_device++;
            }
        } else {
            /* A manager that refused is not a manager that is absent,
               and the fallback runs anyway: a sprite that did not move
               is better than a pointer the Toolbox and the picture
               disagree about. The errno is kept because "it refused"
               and "it refused with -1" are different investigations. */
            *gCrsrNew = *gCrsrCouple;
            now_cdm_crsr_task();
            route = kNowPeekCursorRouteLowMem;
            if (cell != NULL) {
                cell->last_err = (NowPeekI32)err;
                cell->by_lowmem++;
            }
        }
    } else {
        *gCrsrNew = *gCrsrCouple;
        now_cdm_crsr_task();
        route = kNowPeekCursorRouteLowMem;
        if (cell != NULL) {
            cell->by_lowmem++;
        }
    }

    if (cell != NULL) {
        cell->route = (NowPeekU32)route;
        cell->seq++;                        /* even: settled */
    }
    return route;
}

/* Settle a redraw the interrupt-time caller could not perform.
 *
 * Called from the core's jGNE pass, in whatever process is pumping,
 * which is the first moment since the placement that QuickDraw may be
 * called at all. It is deliberately NOT gated on the act plane being
 * armed: the debt is a picture that disagrees with the machine, and
 * disarming the plane does not make the arrow correct again.
 *
 * The yield rule is re-checked here rather than trusted from the
 * placement, because time has passed and a person may have taken the
 * mouse in between - which is exactly the window this settles into. */
void now_ext_cursor_gne(NowPeekTable *table)
{
    NowPeekCursorCell *cell;
    Point where;

    (void)table;
    if (!gRedrawOwed) {
        return;
    }
    gRedrawOwed = false;
    if (gDevice != NULL && gDevice->whichCursor != NULL) {
        where = gDevice->whichCursor->where;
        if (now_cursor_is_foreign((NowPeekI32)where.h, (NowPeekI32)where.v,
                                  (NowPeekI32)gLastPlaced.h,
                                  (NowPeekI32)gLastPlaced.v)) {
            return;                 /* somebody else has it now */
        }
    }
    *gCrsrObscure = 0;
    HideCursor();
    ShowCursor();
    cell = now_ext_cursor_cell(gTable);
    if (cell != NULL) {
        cell->seq++;
        cell->route = (NowPeekU32)kNowPeekCursorRouteQuickDraw;
        cell->seq++;
    }
}

/* Ask the manager for a device, once, at boot.
 *
 * The capability bit is published only if BOTH the trap is implemented
 * and a device came back, so an application never arms a plane that
 * cannot fire - the same rule P7's install follows. A machine with no
 * cursor device is not a broken machine and this is not an error: every
 * act and every drag behaves exactly as it did before P8, and the
 * picture is the only thing missing. That is the resident-component
 * charter's whole rule about optional components, and it is why the
 * fallback below is a route and not a failure. */
void now_ext_cursor_boot(NowPeekTable *table)
{
    NowPeekCursorCell *cell;
    void *device = NULL;

    if (table == NULL || gBooted) {
        return;
    }
    gTable = table;
    gBooted = true;
    gLastPlaced.h = 0;
    gLastPlaced.v = 0;

    /* THE CELL IS REACHED DIRECTLY HERE, and only here.
       now_ext_cursor_cell() checks `magic`, and at boot MAGIC HAS NOT
       COMMITTED YET - the core writes it last, deliberately, so that a
       reader which sees the table the instant it becomes valid finds
       every plane already advertised. So the accessor answers NULL for
       the resident's own table during its own boot, and the first build
       of this plane used it: cursor_format was zeroed, the capability
       bit was never published, `mouseloc` reported no rows, and the
       whole plane read exactly like a machine whose Cursor Device
       Manager had no device. Watched 2026-08-07, caps=255.

       P7's boot writes `table->drag.state` directly for the same reason.
       The LENGTH check is kept, because that one is about the block this
       binary allocated and is meaningful now. */
    if (table->length < (NowPeekU32)(offsetof(NowPeekTable, cursor)
                                     + sizeof(NowPeekCursorCell))) {
        return;
    }
    table->cursor_format = (NowPeekU32)kNowPeekCursorFormatV1;
    cell = &table->cursor;
    cell->seq = 0;
    cell->route = (NowPeekU32)kNowPeekCursorRouteNone;
    cell->asked = 0;
    cell->by_device = 0;
    cell->by_lowmem = 0;
    cell->yielded = 0;
    cell->last_err = 0;
    cell->device_found = 0;

    if (!cursor_manager_present()) {
        return;
    }
    /* NULL in, first device out - the manager's own idiom. A non-zero
       OSErr or a NULL device both mean the same thing here and are not
       distinguished, because there is nothing different to do about
       them. */
    if (now_cdm_next_device(&device) != 0 || device == NULL) {
        return;
    }
    gDevice = (CursorDevicePtr)device;
    cell->device_found = 1;
    table->caps |= (NowPeekU32)kNowPeekTableCapCursor;
}
