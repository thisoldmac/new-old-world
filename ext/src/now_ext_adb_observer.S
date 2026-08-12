/* Passive ADB service-routine wrapper.

   The ADB Manager supplies A0=Pascal packet, A1=service routine,
   A2=handler data area, and D0=command. Preserve that exact register frame
   around the observer, call the incumbent with its own routine pointer in A1,
   then preserve its return frame while the observer commits the after-state.
 */

    .text
    .even
    .globl now_ext_adb_observer_entry
    .extern now_ext_adb_observer_begin
    .extern now_ext_adb_observer_end
    .extern gNowADBObserverOriginalHandler

now_ext_adb_observer_entry:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    move.l %d0,-(%sp)
    move.l %a0,-(%sp)
    jsr now_ext_adb_observer_begin
    addq.l #8,%sp
    movem.l (%sp)+,%d0-%d7/%a0-%a6

    movea.l gNowADBObserverOriginalHandler,%a1
    cmpa.l #0,%a1
    beq.s .Lafter
    jsr (%a1)

.Lafter:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_adb_observer_end
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    rts
