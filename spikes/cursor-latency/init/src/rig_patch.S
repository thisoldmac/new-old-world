/*
 * rig_patch.S - trap trampolines that give the picture a task-time
 * moment INSIDE somebody else's tracking loop.
 *
 * WHY THIS FILE EXISTS. Measured on this bench, 2026-08-07: the
 * pointer's POSITION follows perfectly under every load (one tick,
 * never out of order), and its PICTURE freezes completely whenever no
 * application reaches WaitNextEvent - verified from outside the guest,
 * zero pixels changed. The picture is settled with a QuickDraw
 * HideCursor/ShowCursor pair, QuickDraw needs task time, and the jGNE
 * filter that provided it only runs when somebody calls GetNextEvent.
 * During a drag, nobody does.
 *
 * But a tracking loop is not silent: DragGrayRgn, TrackControl and
 * every hand-written drag call GetMouse, StillDown and Button, over and
 * over, at task time, in the tracking application's own context. That
 * is exactly the moment the picture needs and cannot otherwise get.
 *
 * These trampolines do NOT change what the traps do. They preserve
 * every register, call one C function that settles the picture only if
 * a debt is owed, restore, and jump to the incumbent with the stack
 * UNTOUCHED - so the real trap sees precisely its own frame and a call
 * behaves exactly as it would with no extension present. That is the
 * whole reason none of the Pascal result-slot hazards in this project's
 * other patch file apply here: nothing is answered, only chained.
 *
 * The debt is checked before the work, so the common case - no debt -
 * is a load, a test and a jump. A tracking loop calls GetMouse
 * thousands of times a second and the writer can owe at most one
 * picture per tick.
 */

    .text
    .even
    .globl rig_getmouse_patch
    .globl rig_stilldown_patch
    .globl rig_button_patch
    .extern rig_settle_picture
    .extern gRigOldGetMouse
    .extern gRigOldStillDown
    .extern gRigOldButton

rig_getmouse_patch:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr rig_settle_picture
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    movea.l gRigOldGetMouse,%a0
    jmp (%a0)

rig_stilldown_patch:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr rig_settle_picture
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    movea.l gRigOldStillDown,%a0
    jmp (%a0)

rig_button_patch:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr rig_settle_picture
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    movea.l gRigOldButton,%a0
    jmp (%a0)
