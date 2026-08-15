/* Continuity's held-button Time Manager entry. Timer.h's callback receives
 * the TMTask pointer in A1, while an ordinary C function expects it on the
 * stack. Preserve the interrupted world, bridge that one argument, return.
 */

    .text
    .even
    .globl now_ext_continuity_tm_entry
    .extern now_ext_continuity_tick

now_ext_continuity_tm_entry:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    move.l %a1,-(%sp)
    jsr now_ext_continuity_tick
    addq.l #4,%sp
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    rts
