#ifndef NOW_PIXELS_H
#define NOW_PIXELS_H

#include <Carbon.h>

#include "capture.h"

/* Wire pixel export. PICT is the guest's DISK format — modern macOS cannot
   decode QuickDraw pictures, so the wire carries a format both sides own:
   rows top-to-bottom, each optionally PackBits-compressed and prefixed with
   a big-endian u16 packed length. Indexed depths (<= 8) prepend the palette
   as `palette_bytes` of RGB triples so the host needs no hardcoded CLUT. */

typedef struct {
    Handle data;              /* palette block (if any) followed by rows */
    long palette_bytes;       /* 0 for direct-colour depths */
    long total_bytes;         /* GetHandleSize(data) */
    Boolean packed;           /* rows are PackBits-compressed */
    long encode_ms;
} PixelBlob;

/* Exports `image` into a wire blob. `pack` requests PackBits rows; it is
   honoured only where it helps (>= 8-bit rows), otherwise raw is used and
   `packed` reports what actually happened. Caller disposes blob->data. */
int now_pixels_export(CaptureImage *image, Boolean pack, PixelBlob *blob);

void now_pixels_dispose(PixelBlob *blob);

#endif
