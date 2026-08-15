#include "Retro68.r"

type 'INIT' {
    RETRO68_CODE_TYPE
};

/*
 * sysHeap + locked keeps the resident code at a fixed system-heap
 * address, so the RETRO68_RELOCATE() in _start stays valid for the life
 * of the boot - the Time Manager task, the jGNE filter and the Gestalt
 * selector all call into it forever. preload loads it before _start;
 * DetachResource in _start keeps it resident once the extension file
 * closes.
 *
 * The name says what it is on purpose. It is visible in the Extensions
 * folder, in the startup parade and in a conflict report, and a rig that
 * looks like a product in any of those places is how an instrument gets
 * quoted as a result.
 */
resource 'INIT' (128, "CursorRig (MEASUREMENT RIG)", sysHeap, locked, preload) {
    dontBreakAtEntry, $$read("CursorRig.flt");
};
