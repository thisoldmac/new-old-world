/*
 * vprobe68.h - the measuring half of vprobe on NOW-68K.
 *
 * The Toolbox-facing sibling of n68_vprobe.h: it walks to the screen's
 * PixMap, characterises the machine's clock, times raw framebuffer reads
 * by access width and by the two 68K bulk idioms (MOVEM.L and the 68882's
 * fmove.d), times a CopyBits baseline, checks that a raw read sees the
 * same pixels CopyBits copies, and fills an N68VProbeTable with rows a
 * person can read.
 *
 * WHY IT EXISTS - the same reason the PowerPC guest's vprobe.c does. Every
 * capture or streaming design on this machine is a bet about what reading
 * VRAM costs, and on the PB1400c that bet turned out to be wrong in an
 * interesting way: the bus charged per TRANSACTION rather than per byte,
 * so bandwidth doubled with each access-width doubling and unrolling
 * changed nothing (docs/vram-readout.md). Whether that holds on a 33 MHz
 * 68030 is exactly what this file is for, and the answer changes the
 * design rather than decorating it. `vprobe` therefore stays in the
 * command table afterwards: it is the regression check for any future
 * capture work, and the first thing to run on new hardware.
 *
 * THE HYPOTHESIS THIS RUN IS SHAPED AROUND. MOVEM.L can convert into
 * BURST memory cycles on a 68030, and a burst is a cache-line fill - so
 * bursting is coupled to whether the framebuffer is cacheable at all. The
 * "movem.l x8" and "Reread 32" rows are meant to be read TOGETHER:
 *
 *   reread == first,  movem.l ~= move.l   uncached, no burst: the bus
 *                                         charges per transaction exactly
 *                                         as it did on the 1400c, and the
 *                                         capture design carries over -
 *                                         widen the access, read fewer
 *                                         bytes, never re-read.
 *   reread == first,  movem.l >> move.l   uncached but bursting: the 030
 *                                         is filling lines from VRAM even
 *                                         though it cannot keep them.
 *                                         Bulk reads win and a capture
 *                                         stage here should be built on
 *                                         MOVEM.L, not on the widest
 *                                         single load.
 *   reread << first                       the framebuffer is CACHED, and
 *                                         every number above it is a
 *                                         cache measurement rather than a
 *                                         VRAM one. Nothing in the 1400c
 *                                         design carries over; a warm-read
 *                                         strategy exists and has to be
 *                                         measured on its own terms.
 *   reread << first,  movem.l ~= move.l   cached but not bursting -
 *                                         possible if the line is already
 *                                         resident; treat the widths as
 *                                         measuring the CPU, not the bus.
 *
 * A number nobody can interpret is not a measurement, so those four
 * readings are written down before the run rather than after it.
 *
 * IT TAKES TIME, AND NOTHING IN A READ LOOP PUMPS THE WIRE. The host
 * declares a guest dead after ~65 s of silence (wire68.c's
 * kWireDeadTicks). Every phase here is therefore bounded to
 * kVProbePhaseBudgetUs by measuring a small slice first and shortening the
 * pass to fit (n68_vprobe_scaled_bytes), and the wire is pumped between
 * phases. Worst case for the whole run is stated in vprobe68.c beside the
 * arithmetic that bounds it. The run still wants a still screen, exactly
 * as the PowerPC guest's does.
 */
#ifndef NOW68K_VPROBE68_H
#define NOW68K_VPROBE68_H

#include "n68_vprobe.h"

typedef enum {
    kVProbe68OK = 0,
    kVProbe68Busy,        /* already running: a pumped request re-entered */
    kVProbe68NoScreen,    /* no main device / no PixMap to walk to */
    kVProbe68Geometry     /* the PixMap did not check out - refused to read */
} VProbe68Status;

/* Runs the whole probe, filling `t` (which is initialised here). On any
 * status but kVProbe68OK, `why` carries the short sentence for the caller
 * to put in an error reply and `t` is left empty.
 *
 * REFUSES RATHER THAN GUESSES. Everything it dereferences is checked by
 * n68_vprobe_geometry_ok() first, because on a 68030 a wrong base pointer
 * is a bus error and a dead machine, not a strange number.
 *
 * NOT free of TIME and not re-entrant: it pumps the wire between phases,
 * and a command.request that arrives during one of those pumps can reach
 * this function again on the same stack. The second call answers
 * kVProbe68Busy rather than running a second probe inside the first, which
 * would measure the first one's stalls. Same hazard and the same shape of
 * fix as proc68.c's `pumping` guard. */
VProbe68Status vprobe68_run(N68VProbeTable *t, char *why, long why_cap);

#endif /* NOW68K_VPROBE68_H */
