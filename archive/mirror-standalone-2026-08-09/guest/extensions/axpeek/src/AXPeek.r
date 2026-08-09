#include "Retro68.r"

type 'INIT' {
	RETRO68_CODE_TYPE
};

/*
 * sysHeap + locked keep the resident patch at a fixed system-heap address so
 * the RETRO68_RELOCATE() in _start stays valid after boot (docs/41). preload
 * loads it before _start runs; DetachResource in _start keeps it resident.
 */
resource 'INIT' (128, "TBT AXPeek", sysHeap, locked, preload) {
	dontBreakAtEntry, $$read("AXPeek.flt");
};
