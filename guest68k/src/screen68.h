/*
 * screen68.h - the walk to this Mac's framebuffer, and one band of
 * offscreen at the screen's own depth and colour table.
 *
 * IT WAS vprobe68.c's, AND IT IS STILL ONE WALK. Both things that read
 * this machine's screen - `vprobe`, which measures what reading costs, and
 * `screenshot`, which captures it - need the same three answers: where the
 * framebuffer is, whether it is safe to touch, and how to move a band of
 * it into a port. A second copy of that walk would be a second set of
 * geometry checks to keep honest, and the failure mode of the one that
 * fell behind is a bus error on a 68030, in another room. So the walk
 * moved here when the second caller arrived, unchanged in behaviour - see
 * vprobe68.c, which now calls it and no longer contains it.
 *
 * FAIL-CLOSED IS THE POINT. Everything below n68_vprobe_geometry_ok() is
 * refused rather than guessed at. A PixMap this code walked to might not
 * be a PixMap at all if a system version moved a field, and finding that
 * out by dereferencing is how a machine dies mid-run.
 */
#ifndef NOW68K_SCREEN68_H
#define NOW68K_SCREEN68_H

#include <Quickdraw.h>
#include <QDOffscreen.h>

/* Microseconds(), the trap every timed thing in this tree reads. It lives
 * here rather than in each caller because vprobe and screenshot must be
 * timed by the SAME clock: their numbers are compared against each other
 * (docs/vram-readout-68k.md), and two clocks with different resolutions
 * would make that comparison quietly wrong. Only the low half is used - it
 * wraps every ~71 minutes and no phase in this tree is longer than a few
 * seconds. vprobe68.c carries the full note on why the trap is taken on
 * the documentation rather than gated by a trap-availability check. */
unsigned long screen68_micros(void);

typedef enum {
    kScreen68OK = 0,
    kScreen68NoScreen,    /* no main device / no PixMap to walk to */
    kScreen68Geometry     /* the PixMap did not check out - refused to read */
} Screen68Status;

typedef struct {
    unsigned long base;
    long          row_bytes;
    long          width;
    long          height;
    long          depth;
    long          bytes;
    long          visible_row;   /* bytes of a row that hold pixels */
    Rect          bounds;        /* global, as QuickDraw sees it */
    PixMapHandle  pix;           /* NULL when there is no Color QuickDraw */
} Screen68;

/* Walks to the framebuffer. Two routes, because a caller should say
 * something useful on a machine without Color QuickDraw rather than
 * refuse: the GDevice's PixMap when there is one, and QuickDraw's own
 * screenBits otherwise. Whichever route produced the numbers, they go
 * through n68_vprobe_geometry_ok() before anything is dereferenced.
 *
 * `who` names the caller in the refusal sentence ("vprobe", "screenshot"),
 * so a person reading a one-line error knows which capability declined and
 * on what grounds. */
Screen68Status screen68_info(Screen68 *s, const char *who,
                             char *why, long why_cap);

/* One band of offscreen at the screen's own depth AND colour table. */
typedef struct {
    GWorldPtr    world;
    PixMapHandle pix;
    short        rows;
    long         row_bytes;
    Ptr          base;
} Band68;

/* Opens a `rows`-tall band the width of the screen. Returns 0 if there is
 * no Color QuickDraw or no memory for it; the band is clamped to the
 * screen's height.
 *
 * THE COLOUR TABLE IS NOT A DETAIL. CopyBits between two 8-bit pixmaps
 * with different tables translates indices, which would make vprobe's
 * fidelity comparison fail on a perfectly good copy and would make
 * screenshot record remapped pixels. */
int screen68_band_open(Band68 *b, const Screen68 *s, short rows);
void screen68_band_close(Band68 *b);

/* Copies rows [top, top + b->rows) of the screen into the band and returns
 * what the CopyBits itself cost, in microseconds. The port swap is outside
 * the timed region on purpose: the number is meant to be comparable with a
 * raw read of the same bytes, not with a whole capture pipeline.
 *
 * The band is the DESTINATION here. screenshot uses the same call with a
 * picture open on the band's port, where CopyBits records instead of
 * blitting and the band's pixels are never written at all - see shot68.c,
 * which is the one place that distinction matters. */
unsigned long screen68_band_copy(Band68 *b, const Screen68 *s, long top);

#endif /* NOW68K_SCREEN68_H */
