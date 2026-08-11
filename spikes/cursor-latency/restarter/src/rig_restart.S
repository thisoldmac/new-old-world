/*
 * rig_restart.S - _Shutdown, selector 2 (restart).
 *
 * Shutdown.h declares ShutDwnStart as THREEWORDINLINE(0x3F3C, 0x0002,
 * 0xA895) and says "CarbonLib: not available", so there is nothing to
 * link against on either side: GCC ignores the inline and Carbon
 * dropped the manager. The three words ARE the implementation - push
 * the selector, trap - so they are written out here in a non-Carbon 68K
 * application instead.
 */

    .text
    .even
    .globl rig_shut_dwn_start
rig_shut_dwn_start:
    move.w #2,-(%sp)
    .short 0xA895
    rts
