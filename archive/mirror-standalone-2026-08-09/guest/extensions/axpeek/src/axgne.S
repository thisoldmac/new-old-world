/*
 * axgne.S - classic 68K GetNextEvent filter shim.
 *
 * GNEFilter is not a C ABI callback. Apple documents inputs in A1, D0, and the
 * stack, with the Boolean result returned on the stack. Preserve the incoming
 * register state and stack exactly, run the allocation-free sampler, then
 * tail-chain the filter that was installed before AXPeek.
 */

    .text
    .even
    .globl ax_gne_filter
    .extern ax_gne_sample
    .extern gOldGNEFilter
    .extern gLastA5
    .extern gLastWindowList
    .extern gLastTicks

    .set kSampleTicks,6

ax_gne_filter:
    /* Preserve scratch registers. A new A5 world or a changed WindowList root
     * is sampled immediately; an unchanged context enters C at most at 10 Hz. */
    movem.l %d1/%a0,-(%sp)
    move.l 0x0904,%d1
    cmp.l gLastA5,%d1
    bne.s ax_gne_sample_due
    move.l 0x09d6,%d1
    cmp.l gLastWindowList,%d1
    bne.s ax_gne_sample_due
    move.l 0x016a,%d1
    sub.l gLastTicks,%d1
    cmpi.l #kSampleTicks,%d1
    bcs.s ax_gne_chain_fast

ax_gne_sample_due:
    movem.l (%sp)+,%d1/%a0
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr ax_gne_sample
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    bra.s ax_gne_chain

ax_gne_chain_fast:
    movem.l (%sp)+,%d1/%a0

ax_gne_chain:
    /* A0 is not an input to the documented filter ABI. */
    movea.l gOldGNEFilter,%a0
    cmpa.l #0,%a0
    beq.s 1f
    jmp (%a0)
1:
    rts
