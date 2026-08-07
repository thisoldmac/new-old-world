/*
 * now_ext_cursor_cdm.S - two Cursor Device Manager calls, in assembly
 * because this toolchain cannot emit them any other way.
 *
 * WHY THIS FILE EXISTS AT ALL
 * ---------------------------
 * CursorDevices.h declares the whole manager as 68K inline traps:
 *
 *     EXTERN_API( OSErr ) CursorDeviceMoveTo(CursorDevicePtr ourDevice,
 *                                            long absX, long absY)
 *                                            TWOWORDINLINE(0x7001, 0xAADB);
 *
 * TWOWORDINLINE is a directive for the compilers Universal Interfaces
 * was written for. GCC ignores it, exactly as it ignores LowMem.h's
 * accessor macros past CrsrBusy - so a C call to CursorDeviceMoveTo
 * links against a symbol that does not exist. The two words themselves
 * are the entire routine: `moveq #selector,%d0` and the trap.
 *
 * THE CALLING CONVENTION IS THE PART TO GET RIGHT
 * ------------------------------------------------
 * EXTERN_API is PASCAL. The caller reserves space for the result FIRST,
 * pushes parameters LEFT TO RIGHT, and the trap removes the parameters
 * and leaves the result behind. That is the opposite of the C convention
 * these functions are called with on either side of this file, and
 * getting it backwards does not fail loudly - it moves the cursor to a
 * point assembled out of half of one coordinate and half of another,
 * which reads as an acceleration bug rather than as an ABI bug.
 *
 * Toolbox traps preserve D3-D7 and A2-A6 and clobber D0-D2 / A0-A1. D0
 * and D1, A0 and A1 are scratch under the m68k C ABI too, so only D2
 * needs saving here.
 *
 * WHY THE 68K PATH AND NOT THE POWERPC ONE. CursorDevices.h carries a
 * warning in capitals that PowerPC callers need CursorDevicesGlue.o
 * because the InterfaceLib MixedMode transition for this manager was
 * wrong in ROM. That warning is about calling it FROM PowerPC. This is a
 * 68K INIT issuing the trap directly, which is the path the ADB mouse
 * driver itself takes, so none of that applies.
 */

    .text
    .even
    .globl now_cdm_move_to
    .globl now_cdm_next_device

| OSErr now_cdm_move_to(void *device, long absX, long absY)
|
| Selector 1. Called from the drag Time Manager task at INTERRUPT TIME,
| which is legitimate for exactly one reason: this is the call a mouse
| driver's own interrupt handler makes, sixty times a second, and the
| manager is written for that caller.
now_cdm_move_to:
    link    %a6,#0
    move.l  %d2,-(%sp)
    subq.l  #2,%sp                  | Pascal result space (OSErr, a word)
    move.l  8(%a6),-(%sp)           | ourDevice
    move.l  12(%a6),-(%sp)          | absX
    move.l  16(%a6),-(%sp)          | absY
    moveq   #1,%d0
    .short  0xAADB                  | _CursorDeviceDispatch
    move.w  (%sp)+,%d0              | the trap popped the parameters
    ext.l   %d0
    move.l  (%sp)+,%d2
    unlk    %a6
    rts

| OSErr now_cdm_next_device(void **device)
|
| Selector 11. With *device NULL it answers the FIRST device in the
| manager's list, which is how a caller with no device of its own gets
| one; with a device it answers the next. This extension only ever wants
| the first, and asks for it once, at boot.
now_cdm_next_device:
    link    %a6,#0
    move.l  %d2,-(%sp)
    subq.l  #2,%sp
    move.l  8(%a6),-(%sp)           | CursorDevicePtr *ourDevice
    moveq   #11,%d0
    .short  0xAADB
    move.w  (%sp)+,%d0
    ext.l   %d0
    move.l  (%sp)+,%d2
    unlk    %a6
    rts

| void now_cdm_crsr_task(void)
|
| Call the cursor task through its jump vector, JCrsrTask (0x08EE).
|
| WHY THIS EXISTS ON TOP OF CursorDeviceMoveTo. The manager call answers
| noErr and its own CursorData record lands exactly on the requested
| point - read from outside the guest, `where` was 760,520 while the
| drawn arrow was still at 419,333, where the emulated DEVICE had last
| left it. So on Mac OS 9 the manager owns the POSITION and something
| else owns the BLIT, and the blit is the cursor task. The pointing
| device's own interrupt handler reaches it through this vector; nothing
| else on this machine appears to, which is why a resident that only sets
| state is a resident whose cursor never draws.
|
| Every register is preserved. This runs at interrupt time inside
| whatever was executing, exactly like the jGNE filter and the Time
| Manager shims beside it, and the cursor task is somebody else's code -
| the same argument now_liveness_tm.S makes about a callback whose ABI is
| not ours to assume.
    .globl now_cdm_crsr_task
now_cdm_crsr_task:
    movem.l %d0-%d7/%a0-%a6,-(%sp)
    move.l  0x08EE,%a0
    jsr     (%a0)
    movem.l (%sp)+,%d0-%d7/%a0-%a6
    rts
