/*
 * qdprobe_gne.S - QD Probe's chained jGNE filter shim.
 *
 * Same ABI contract as the NOW Extension's now_ext_gne.S, which is where
 * this came from and which is metal-proven: preserve every register, run
 * the C applier, restore, tail-chain to the filter installed before us.
 *
 * A jGNE filter is not a C callback - the Event Manager passes the event
 * pointer in A1 and expects the chain to stay intact - so the non-C ABI
 * lives here rather than being approximated in C.
 *
 * Note this shim is NOT the interesting part of this spike. The Event
 * Manager calls a jGNE filter as bare 68K code, which is exactly why a
 * raw pointer works below. QuickDraw's bottleneck procs are the other
 * case, and whether they work at all from here is the question the probe
 * exists to answer (README.md).
 */

    .text
    .even
    .globl qdprobe_gne_filter
    .extern qdprobe_gne_apply
    .extern gQDProbeOldGNEFilter

qdprobe_gne_filter:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    jsr qdprobe_gne_apply
    movem.l (%sp)+,%d0-%d7/%a0-%a6

    movea.l gQDProbeOldGNEFilter,%a0
    cmpa.l #0,%a0
    beq.s 1f
    jmp (%a0)
1:
    rts
