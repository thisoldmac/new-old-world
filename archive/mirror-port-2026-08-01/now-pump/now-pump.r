/*
 * now-pump.r - resource overrides for the act plane's posting context.
 *
 * SIZE (-1) is the whole user-visible design of this application, because
 * everything else about it is invisible on purpose. Each flag is here for
 * a stated reason and the wrong value on any of them breaks the thing the
 * process exists to do:
 *
 *   onlyBackground - it owns no user interface. This keeps it out of
 *     foreground application switching and stops it owning the menu bar,
 *     so it never becomes the front process. A pump that came to the
 *     front would break EVERY act it exists to enable: the click it posts
 *     is for the application the request names, and the Event Manager
 *     gives a press to whoever is frontmost.
 *   canBackground + acceptSuspendResumeEvents - it must keep getting the
 *     processor while another application is frontmost, which is the only
 *     state it ever runs in. A cannotBackground build would starve
 *     exactly when a click is due.
 *   dontGetFrontClicks - for the same reason as onlyBackground: a click
 *     belongs to the application under the pointer, not to us.
 *   isHighLevelEventAware - so the quit Apple Event REACHES it, from the
 *     application at the end of a host session or from the Finder at
 *     shutdown. An application that cannot be reaped has to be killed by
 *     restarting the machine; the heartbeat watch in main.c is the second
 *     answer to that question, not the first.
 *   onlyLocalHLEvents - nothing off this machine has any business
 *     addressing a process whose only job is to press the mouse.
 *   is32BitCompatible - the supported range (8.6-9.2.2) is 32-bit
 *     addressing throughout.
 *
 * The partition is small because the process holds nothing: no buffers,
 * no walk state, no transfers. Its working set is one event record, the
 * Toolbox's own per-application overhead, and a pointer into the system
 * heap. 64 KB is headroom over that rather than a measured floor -
 * measured on a machine is a thing this file cannot claim.
 */
#include "Processes.r"

#ifndef NOW_PUMP_PARTITION_KB
#define NOW_PUMP_PARTITION_KB 64
#endif

resource 'SIZE' (-1) {
    reserved,
    acceptSuspendResumeEvents,
    reserved,
    canBackground,
    needsActivateOnFGSwitch,
    onlyBackground,
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
    NOW_PUMP_PARTITION_KB * 1024,
    NOW_PUMP_PARTITION_KB * 1024
};
