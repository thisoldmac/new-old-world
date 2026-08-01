#include "Retro68.r"

type 'INIT' {
	RETRO68_CODE_TYPE
};

/*
 * sysHeap + locked keep the resident hook at a fixed system-heap address so the
 * RETRO68_RELOCATE() in _start stays valid after boot; preload loads it before
 * _start runs, and DetachResource in _start keeps it resident.
 */
resource 'INIT' (128, "TBT Portal", sysHeap, locked, preload) {
	dontBreakAtEntry, $$read("Portal.flt");
};
