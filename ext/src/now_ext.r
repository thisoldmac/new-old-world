#include "Retro68.r"

type 'INIT' {
    RETRO68_CODE_TYPE
};

/*
 * sysHeap + locked keep the resident code at a fixed system-heap
 * address, so the RETRO68_RELOCATE() in _start stays valid for the life
 * of the boot (the jGNE filter and Gestalt selector call into it
 * forever). preload loads it before _start; DetachResource in _start
 * keeps it resident after the extension file closes. The pattern is
 * qdpeek/AXPeek, metal-proven.
 */
resource 'INIT' (128, "NOW Extension", sysHeap, locked, preload) {
    dontBreakAtEntry, $$read("NowExt.flt");
};
