/*
 * shotsrc68.h - the screen as a stream of bytes the sender can pull.
 *
 * n68_bytesrc.h says why it exists rather than a file sender: "the reason
 * this interface exists is a screen capture", which "cannot be buffered on
 * this machine at all". This is that source.
 *
 * ---- Why this reads the screen and not a picture -----------------------
 *
 * shot68.c's capture produces a packed PICT by handing the whole frame to
 * QuickDraw in ONE CopyBits that runs to completion in ~480 ms and cannot
 * be suspended. `fill()` is a pull - "produce up to cap bytes and return
 * promptly" - and there is no way to pull from inside a call that is
 * pushing. Nothing on this machine can invert that: no threads, no
 * coroutines, and the banded recording that would have made it
 * incremental is the thing that killed QuickDraw on the third band
 * (docs/open-issues.md).
 *
 * So this source does not use the picture path at all. It reads the
 * framebuffer directly, a band at a time, through the same walk vprobe and
 * screenshot share (screen68.h) - which is also exactly what the contract's
 * `raw` encoding is: rows, top to bottom, verbatim. The two paths meet at
 * the screen and nowhere else, and that is the honest shape rather than a
 * compromise: PICT is the disk format, raw rows are the wire format, and
 * the contract already said so.
 *
 * ---- How it keeps n68_bytesrc.h's five promises ------------------------
 *
 * 1. `total` EXACT BEFORE THE FIRST FILL - n68_shotwire_plan() computes it
 *    from the PixMap: palette plus visible rows. No packing, so no
 *    unknowable length (n68_shotwire.h carries why packbits cannot make
 *    this promise on this machine).
 * 2. fill() RETURNS PROMPTLY - it copies at most one chunk (4 KB) per
 *    call, which at the 180c's measured ~1.5 MB/s framebuffer read is
 *    about 3 ms. It never reads a whole band it was not asked for.
 * 3. fill() DOES NOT ALLOCATE - the palette is snapshotted into this
 *    struct when the source is opened, and the rows are copied straight
 *    out of VRAM into the sender's buffer. There is no intermediate.
 * 4. fill() DOES NOT TOUCH THE WIRE - no pump, no WaitNextEvent, nothing
 *    that reaches them.
 * 5. THE SOURCE DOES NOT OUTLIVE THE TRANSFER - close() shields nothing
 *    and frees nothing, because this source holds no handle and no file;
 *    it only marks itself shut so a late fill cannot read a screen the
 *    caller has stopped caring about.
 *
 * ---- The cursor, and what it means to shield a stream ------------------
 *
 * shot68.c shields each band across a read that takes 200 ms. A stream
 * cannot do that: the read is spread across as many event-loop passes as
 * the wire needs, and hiding the cursor for the whole transfer would take
 * it away from the person at the machine for seconds. So this source
 * shields ONLY the rows it is copying, on each fill, and shows the cursor
 * again before it returns. The cost is that a cursor moved mid-transfer
 * can appear in a row that was already sent and not in one that has not -
 * a capture of a screen that genuinely changed while it was being read,
 * which is what a streamed capture is. shot68.c's one-shot picture remains
 * the coherent one.
 */
#ifndef NOW68K_SHOTSRC68_H
#define NOW68K_SHOTSRC68_H

#include "n68_bytesrc.h"
#include "n68_shotwire.h"
#include "screen68.h"

typedef enum {
    kShotSrc68OK = 0,
    kShotSrc68NoScreen,   /* no main device / no PixMap to walk to */
    kShotSrc68Geometry,   /* the PixMap did not check out - refused to read */
    kShotSrc68Depth       /* not 8-bit; this lane will not convert */
} ShotSrc68Status;

/* Everything the source owns, so promise (3) can be kept: the palette is
 * copied here once at open, and nothing is allocated afterwards.
 *
 * STATIC BUDGET: 768 bytes of palette plus the Screen68 and a few scalars,
 * ~830 bytes. The caller owns the instance; wire68.c holds one beside its
 * transfer state, exactly as it holds one file source. */
typedef struct {
    N68ShotWirePlan plan;
    Screen68        screen;
    long            offset;     /* bytes handed to the sender so far */
    int             shut;       /* close() ran; a late fill reads nothing */
    unsigned char   palette[kN68ShotWirePaletteBytes];
} ShotSrc68;

/* Walks to the screen, snapshots its colour table, and fills `src` with a
 * byte source over it. `capture_ms` gets the walk's cost so capture.begin
 * can carry it (there is no separate blit to time on this path - the
 * reading IS the transfer, which is the point).
 *
 * On any status but kShotSrc68OK, `why` carries the sentence for the
 * caller's refusal and `src` is left unusable. */
ShotSrc68Status shotsrc68_open(ShotSrc68 *src, N68ByteSource *out,
                               long *capture_ms, char *why, long why_cap);

#endif /* NOW68K_SHOTSRC68_H */
