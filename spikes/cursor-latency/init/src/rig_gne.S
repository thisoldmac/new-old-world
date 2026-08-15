/*
 * rig_gne.S - the chained jGNE filter shim.
 *
 * A jGNE filter is not a C callback either: the Event Manager passes
 * the event record in A1 and expects the previously-installed filter to
 * be tail-chained. The rig does not read the event; it uses the filter
 * only as a clock - "somebody reached an event loop" - which is the one
 * moment the picture debt can be settled with real QuickDraw.
 *
 * Chaining is not optional. Whatever was in jGNE before us is somebody
 * else's resident, and dropping it is how a machine loses its
 * screen-saver, its extension, or its input method with no diagnosis
 * available afterwards.
 */

    .text
    .even
    .globl rig_gne_filter
    .extern rig_gne_pass
    .extern gRigOldGNEFilter

rig_gne_filter:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr rig_gne_pass
    movem.l (%sp)+,%d0-%d7/%a0-%a6

    movea.l gRigOldGNEFilter,%a0
    cmpa.l #0,%a0
    beq.s 1f
    jmp (%a0)
1:
    rts
