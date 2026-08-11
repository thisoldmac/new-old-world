/*
 * now_ext_gne.S - the NOW Extension's chained jGNE filter shim (M0).
 *
 * A jGNE filter is not a C callback: the Event Manager passes the event
 * pointer in A1, the boolean result in D0/on the stack, and expects the
 * previously-installed filter to be tail-chained. Same ABI contract as
 * tbt's axgne.S / qdgne.S, which are metal-proven.
 *
 * Preserve every register, run the C applier (which does one cheap
 * heartbeat store), restore, then jump to the filter installed before
 * us so the chain stays intact. At M0 the applier is deliberately
 * trivial; P1's anchor capture hangs off the same shim later.
 */

    .text
    .even
    .globl now_ext_gne_filter
    .extern now_ext_gne_apply
    .extern gNowExtOldGNEFilter

now_ext_gne_filter:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr now_ext_gne_apply
    movem.l (%sp)+,%d0-%d7/%a0-%a6

    movea.l gNowExtOldGNEFilter,%a0
    cmpa.l #0,%a0
    beq.s 1f
    jmp (%a0)
1:
    rts
