#include "proc_actions.h"

#include <Carbon.h>

OSErr now_proc_bring_to_front(const ProcessSerialNumber *psn)
{
    return SetFrontProcess(psn);
}

OSErr now_proc_ask_quit(const ProcessSerialNumber *psn)
{
    AEAddressDesc target;
    AppleEvent event;
    AppleEvent reply;
    OSErr err;

    err = AECreateDesc(typeProcessSerialNumber, psn, sizeof *psn, &target);
    if (err != noErr) {
        return err;
    }
    err = AECreateAppleEvent(kCoreEventClass, kAEQuitApplication, &target,
                             kAutoGenerateReturnID, kAnyTransactionID,
                             &event);
    AEDisposeDesc(&target);
    if (err != noErr) {
        return err;
    }
    /* No reply, no interaction: a cooperative quit the app may decline is
       still the most force the platform safely allows. */
    err = AESend(&event, &reply, kAENoReply | kAENeverInteract,
                 kAENormalPriority, kAEDefaultTimeout, NULL, NULL);
    AEDisposeDesc(&event);
    return err;
}
