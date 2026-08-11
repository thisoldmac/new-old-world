#include "Retro68.r"

type 'INIT' {
    RETRO68_CODE_TYPE
};

/*
 * sysHeap + locked + preload, the same residence pattern as the NOW
 * Extension and tbt's qdpeek/AXPeek. DetachResource in _start keeps the
 * code alive after the file closes.
 *
 * Named "QD Probe" on purpose - this is a throwaway spike and its name
 * says so on the disk it is installed to, so nobody finds it in an
 * Extensions folder a month from now and takes it for a NOW component.
 */
resource 'INIT' (128, "QD Probe", sysHeap, locked, preload) {
    dontBreakAtEntry, $$read("QDProbe.flt");
};
