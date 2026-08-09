#include "Retro68.r"

type 'INIT' {
	RETRO68_CODE_TYPE
};

/*
 * sysHeap + locked keep the resident hooks at a fixed system-heap address so
 * the RETRO68_RELOCATE() in _start stays valid after boot (see AXPeek.r).
 * preload loads it before _start; DetachResource in _start keeps it resident.
 */
resource 'INIT' (128, "TBT QDPeek", sysHeap, locked, preload) {
	dontBreakAtEntry, $$read("QDPeek.flt");
};
