/*
 * now_liveness_tm.S - the liveness Time Manager task's entry shim (P6).
 *
 * A Time Manager task is not a C callback, for exactly the reason a jGNE
 * filter is not one (now_ext_gne.S, the sibling of this file). The
 * headers say so themselves and they are unambiguous:
 *
 *     typedef CALLBACK_API_REGISTER68K( void, TimerProcPtr,
 *                                       (TMTaskPtr tmTaskPtr) );
 *
 * and on classic 68K, ConditionalMacros.h collapses that to a function
 * of NO arguments — "On classic 68k, some callbacks are register based.
 * The only way to write them in C is to make a function with no
 * parameters and a void return. Inside the function you manually get and
 * set registers." Timer.h's own procinfo agrees: uppTimerProcInfo is
 * 0x0000B802, which its comment spells out as a register-based function
 * taking four bytes in A1.
 *
 * So the Time Manager passes the task record in **A1**, and a C function
 * written as `void tick(TMTaskPtr)` reads its argument off the STACK
 * instead — a pointer that belongs to whatever was interrupted. There is
 * no routine descriptor to save it: on classic 68K NewRoutineDescriptor
 * is a no-op macro returning the ProcPtr unchanged, so `NewTimerProc`
 * hands the Time Manager this address bare.
 *
 * That mis-ABI is the whole of the 2026-08-05 boot hang, and it explains
 * both of that day's symptoms rather than one: a task whose record
 * pointer is garbage re-primes a garbage queue element (so it fires ONCE
 * and stops) and writes its counter through a garbage table pointer (so,
 * once it fires every five seconds, it corrupts the machine out from
 * under the booting Finder).
 *
 * Preserve every register — this runs at interrupt time inside whatever
 * was executing — hand A1 to the C tick as an ordinary stack argument,
 * restore, and return. Nothing is chained: unlike jGNE, a Time Manager
 * task is ours alone.
 */

    .text
    .even
    .globl now_liveness_tm_entry
    .extern now_liveness_tick

now_liveness_tm_entry:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    move.l %a1,-(%sp)               /* the task record, per the procinfo */
    jsr now_liveness_tick
    addq.l #4,%sp
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    rts
