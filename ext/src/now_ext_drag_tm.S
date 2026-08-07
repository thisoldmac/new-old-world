/*
 * now_ext_drag_tm.S - the drag vehicle's Time Manager entry shim (P7).
 *
 * Identical in shape to now_liveness_tm.S, and deliberately its own file
 * rather than a shared one, because the two tasks have different
 * lifetimes: liveness is installed once at boot and never removed, while
 * this one is installed on the first drag and re-primed only while a
 * button is held. A shared trampoline would have to know which.
 *
 * The ABI fact both files rest on is stated once, there, and it is the
 * one that cost 2026-08-05: Timer.h's uppTimerProcInfo is 0x0000B802 -
 * a REGISTER-based callback taking four bytes in A1 - so a C function
 * written as `void tick(TMTaskPtr)` reads its argument off the stack and
 * gets a pointer belonging to whatever was interrupted. On classic 68K
 * NewRoutineDescriptor is a no-op macro, so there is no descriptor to
 * fix it up; the shim is the fix.
 *
 * Preserve every register - this runs at interrupt time inside whatever
 * was executing - hand A1 to the C tick as an ordinary stack argument,
 * restore, and return. Nothing is chained: a Time Manager task is ours
 * alone.
 */

    .text
    .even
    .globl now_ext_drag_tm_entry
    .extern now_ext_drag_tick

now_ext_drag_tm_entry:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    move.l %a1,-(%sp)               /* the task record, per the procinfo */
    jsr now_ext_drag_tick
    addq.l #4,%sp
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    rts
