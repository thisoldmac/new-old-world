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

/* _CursorDeviceDispatch. Passed whole, the way now_content.c passes
   _QDExtensions; NGetTrapAddress masks it. */
#define kNowCursorDeviceTrap 0xAADB
#define kNowUnimplementedTrap 0xA89F

/* OSErr, from the assembly shims - see now_ext_cursor_cdm.S for why they
   cannot be C declarations with TWOWORDINLINE. */
extern long now_cdm_move_to(void *device, long absX, long absY);
extern long now_cdm_next_device(void **device);

static NowPeekTable *gTable = NULL;
static void *gDevice = NULL;
static Point gLastPlaced;
static unsigned long gForeignTicks = 0;
static Boolean gBooted = false;

void now_ext_cursor_boot(NowPeekTable *table);
int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, int owned);
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
int now_ext_cursor_place(NowPeekI32 h, NowPeekI32 v, int owned)
{
    NowPeekCursorCell *cell = now_ext_cursor_cell(gTable);
    Point pt;
    Point raw;
    unsigned long now;
    int route;

    pt.h = (short)h;
    pt.v = (short)v;

    /* Who moved it last? Asked BEFORE our own writes, or the answer is
       always "us". */
    raw = LMGetRawMouseLocation();
    now = (unsigned long)LMGetTicks();
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
                                owned,
                                (NowPeekU32)kNowPeekCursorYieldTicks)) {
        route = kNowPeekCursorRouteYielded;
        if (cell != NULL) {
            cell->yielded++;
        }
    } else if (gDevice != NULL) {
        long err = now_cdm_move_to(gDevice, (long)h, (long)v);
        if (err == 0) {
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
            route = kNowPeekCursorRouteLowMem;
            if (cell != NULL) {
                cell->last_err = (NowPeekI32)err;
                cell->by_lowmem++;
            }
        }
    } else {
        *gCrsrNew = *gCrsrCouple;
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

    table->cursor_format = (NowPeekU32)kNowPeekCursorFormatV1;
    cell = now_ext_cursor_cell(table);
    if (cell == NULL) {
        /* Too short a table to hold the cell: an older application's
           block. The plane stays off rather than writing past it. */
        table->cursor_format = 0;
        return;
    }
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
    gDevice = device;
    cell->device_found = 1;
    table->caps |= (NowPeekU32)kNowPeekTableCapCursor;
}
