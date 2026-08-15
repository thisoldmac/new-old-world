/*
 * rig_cursor.S - Cursor Device Manager glue.
 *
 * CursorDevices.h declares the whole manager as 68K inline traps:
 *
 *     EXTERN_API( OSErr ) CursorDeviceMoveTo(CursorDevicePtr ourDevice,
 *                                            long absX, long absY)
 *                                            TWOWORDINLINE(0x7001, 0xAADB);
 *
 * GCC ignores TWOWORDINLINE, so a C call links against a symbol that
 * does not exist and the two words have to be written out here.
 *
 * THE TWO WORDS ARE INSTRUCTIONS, NOT DATA. This is the whole of a bug
 * that crashed the Finder on this bench, so it is worth spelling out:
 * 0x7001 is not the selector, it is `moveq #1,%d0` - the selector is
 * ONE. The first version of this file assembled `move.w #0x7001,%d0`,
 * which hands the dispatcher 28673 where it expects 1, and it indexes
 * its selector table with it. The symptom was "the application Finder
 * has unexpectedly quit" at boot, in whichever process happened to pump
 * events first, with every other counter in the rig looking healthy.
 *
 * THE PASCAL FRAME IS THE OTHER HALF. EXTERN_API is pascal: the caller
 * reserves space for the result FIRST, pushes parameters LEFT TO RIGHT,
 * and the trap removes the parameters and leaves the result behind.
 * Both of these are FUNCTIONS returning OSErr - including MoveTo, which
 * the first version of this file treated as void, so the trap's 2-byte
 * result was left on the stack on every single call. Getting this
 * backwards does not fail loudly; it corrupts a stack somebody else
 * owns.
 *
 * Toolbox traps preserve D3-D7 and A2-A6 and clobber D0-D2 / A0-A1.
 * D0/D1 and A0/A1 are scratch under the m68k C ABI too, so only D2
 * needs saving.
 *
 * This is a 68K INIT issuing the trap directly - the path the ADB mouse
 * driver itself takes. CursorDevices.h's capitalised warning about
 * needing CursorDevicesGlue.o is about calling the manager FROM
 * PowerPC, which this is not.
 */

    .text
    .even
    .globl rig_cursor_device_move_to
    .globl rig_cursor_next_device

| OSErr rig_cursor_device_move_to(void *device, long absX, long absY)
|
| Selector 1. Called from the Time Manager task at INTERRUPT TIME, which
| is legitimate for one reason: this is the call a mouse driver's own
| interrupt handler makes sixty times a second, and the manager is
| written for that caller.
rig_cursor_device_move_to:
    link    %a6,#0
    move.l  %d2,-(%sp)
    subq.l  #2,%sp                  | pascal result space (OSErr, a word)
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

| OSErr rig_cursor_next_device(void **device)
|
| Selector 11. With *device NULL it answers the FIRST device in the
| manager's list, which is how a caller with no device of its own gets
| one to move.
rig_cursor_next_device:
    link    %a6,#0
    move.l  %d2,-(%sp)
    subq.l  #2,%sp                  | pascal result space
    move.l  8(%a6),-(%sp)           | &device
    moveq   #11,%d0
    .short  0xAADB
    move.w  (%sp)+,%d0
    ext.l   %d0
    move.l  (%sp)+,%d2
    unlk    %a6
    rts
