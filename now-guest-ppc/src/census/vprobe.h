#ifndef NOW_VPROBE_H
#define NOW_VPROBE_H

#include <Carbon.h>

/* VRAM read probes: what does reading the framebuffer actually cost, by
   access method? The ~130 ms full-screen capture is VRAM read bandwidth
   (~8 MB/s via CopyBits, depth-independent), and every faster-streaming
   idea hinges on whether that is the bus's floor or CopyBits overhead.
   The suite measures raw pointer reads at each access width against the
   CopyBits baseline, whether rereads hit a cache, whether partial reads
   scale linearly, and whether raw reads are pixel-faithful.

   The framebuffer pointer comes from GetPixBaseAddr on the screen's own
   PixMap — the address the OS hands any app (classic games drew through
   it); nothing here touches device registers. Still: first metal run
   attended. */

typedef struct {
    char label[24];
    char value[48];
} VProbeRow;

/* Runs the full suite (~3 s: several full-screen reads). Returns the row
   count, or -1 with a reason in err. */
int now_vprobe_run(VProbeRow *rows, int max_rows, char *err, long err_cap);

#endif /* NOW_VPROBE_H */
