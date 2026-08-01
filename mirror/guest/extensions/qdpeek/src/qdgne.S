/*
 * qdgne.S - classic 68K GetNextEvent filter shim for QDPeek.
 *
 * Same ABI contract as AXPeek's axgne.S: GNEFilter is not a C callback (inputs
 * in A1/D0/stack, Boolean result on the stack). Preserve the incoming register
 * state, run the C applier, then tail-chain the filter installed before us.
 *
 * Unlike AXPeek there is no throttle branch: qd_gne_apply is cheap in every
 * context except the one traced app (a couple of low-memory reads and a
 * command-sequence compare), and command application must be prompt. The
 * expensive path — the WindowList repair sweep — runs only when the current
 * A5 matches the traced app, gated inside the C code.
 */

    .text
    .even
    .globl qd_gne_filter
    .extern qd_gne_apply
    .extern gOldGNEFilter

qd_gne_filter:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr qd_gne_apply
    movem.l (%sp)+,%d0-%d7/%a0-%a6

    movea.l gOldGNEFilter,%a0
    cmpa.l #0,%a0
    beq.s 1f
    jmp (%a0)
1:
    rts
