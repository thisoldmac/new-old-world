/*
 * guest68k.r - resource overrides for NOW-68K.
 *
 * SIZE (-1): backgroundAndForeground + needsActivateOnFGSwitch because this
 * IS the user-facing window (unlike appe.r's onlyBackground lifecycle
 * resident); canBackground so a live connection keeps draining while the
 * user works elsewhere, same rationale as chat/client/rsrc/chat.r.
 * isHighLevelEventAware so the Finder's shutdown quit-AE reaches main.c's
 * AEProcessAppleEvent dispatch. Partition is preferred == minimum == 384 KB
 * per the PB180c application-partition budget; there is no headroom to
 * borrow from a larger preferred size on a 4 MB machine.
 */
#include "Processes.r"
#include "Menus.r"

/*
 * A menu bar is not decoration here: without it there is no Cmd-Q, and the
 * only way to end a run on the PowerBook is Special > Restart. Every test
 * cycle would cost a reboot of the machine under test.
 */
resource 'MBAR' (128) {
    { 128, 129 }
};

resource 'MENU' (128) {
    128, textMenuProc, 0x7FFFFFFD, enabled, apple,
    {
        "About NOW-68K...", noIcon, noKey, noMark, plain;
        "-",                noIcon, noKey, noMark, plain
    }
};

resource 'MENU' (129) {
    129, textMenuProc, allEnabled, enabled, "File",
    {
        "Quit", noIcon, "Q", noMark, plain
    }
};

#ifndef NOW68K_PARTITION_KB
#define NOW68K_PARTITION_KB 384
#endif

resource 'SIZE' (-1) {
    reserved,
    acceptSuspendResumeEvents,
    reserved,
    canBackground,
    needsActivateOnFGSwitch,
    backgroundAndForeground,
    dontGetFrontClicks,
    ignoreChildDiedEvents,
    is32BitCompatible,
    isHighLevelEventAware,
    onlyLocalHLEvents,
    notStationeryAware,
    dontUseTextEditServices,
    reserved,
    reserved,
    reserved,
    NOW68K_PARTITION_KB * 1024,
    NOW68K_PARTITION_KB * 1024
};
