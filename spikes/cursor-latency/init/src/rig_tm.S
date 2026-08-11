/*
 * rig_tm.S - the Time Manager task's entry shim.
 *
 * A Time Manager task is a REGISTER-based callback, not a C function.
 * Timer.h says so: uppTimerProcInfo is 0x0000B802, "a register-based
 * routine taking four bytes in A1", and ConditionalMacros.h collapses
 * CALLBACK_API_REGISTER68K on classic 68K to a function of NO
 * arguments. Write `void tick(TMTaskPtr)` in C and it reads its
 * argument off the STACK - a pointer belonging to whatever code was
 * interrupted.
 *
 * Nothing catches it: NewRoutineDescriptor is a no-op macro on classic
 * 68K, so NewTimerProc hands the Time Manager the bare C entry point
 * and the build is clean. The failure is a cold-boot hang with two
 * symptoms from one cause (finding
 * time-manager-task-is-a-register-callback, watched on this same
 * emulated machine).
 *
 * Preserve every register - this runs inside whatever was executing -
 * hand A1 to the C tick as an ordinary stack argument, restore, return.
 * Nothing is chained: a Time Manager task is ours alone.
 */

    .text
    .even
    .globl rig_tm_entry
    .extern rig_tm_tick

rig_tm_entry:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    move.l %a1,-(%sp)                   /* the task record, per the procinfo */
    jsr rig_tm_tick
    addq.l #4,%sp
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    rts
