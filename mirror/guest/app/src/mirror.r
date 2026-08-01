/*
 * mirror.r - resource overrides for the mirror agent.
 *
 * SIZE (-1) flips Retro68's defaults for a faceless background server:
 *
 *   canBackground + acceptSuspendResumeEvents - the agent must keep getting CPU
 *   while it is NOT frontmost, because the whole point is to observe whichever
 *   application IS. A cannotBackground build would starve exactly when the host
 *   needs a scene.
 *
 *   onlyBackground - the agent owns no user interface. This keeps it out of
 *   foreground application switching and stops it owning the menu bar, so it
 *   never perturbs the thing it is mirroring. dontGetFrontClicks for the same
 *   reason: a click belongs to the app under the pointer, not to us.
 *
 *   isHighLevelEventAware - so it RECEIVES the quit Apple Event, from the
 *   Finder at shutdown or from a host tearing the agent down. An app that
 *   cannot be reaped has to be killed by rebooting the machine.
 */
#include "Processes.r"

/* The bounded AX readers, ref resolver, and their escape scratch. Sized like
 * the lab's toolkit worker (656 KB), which carries the same walk code; the
 * agent has no transfer buffers or model runtime, so this is headroom rather
 * than a measured floor. Raise it via -DMIRROR_PARTITION_KB if a walk ever
 * reports a memory failure rather than a cap. */
#ifndef MIRROR_PARTITION_KB
#define MIRROR_PARTITION_KB 656
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
    MIRROR_PARTITION_KB * 1024,
    MIRROR_PARTITION_KB * 1024
};
