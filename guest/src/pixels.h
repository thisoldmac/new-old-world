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

/* --- delta frames -------------------------------------------------------
   A dirty rect is a run of rows trimmed to its changed column span,
   expressed in BYTES into the row so the wire stays depth-agnostic. */

typedef struct {
    short row, n_rows;
    short col_off, col_bytes;
} PixelRect;

enum { kPixelMaxRects = 16 };

/* Diffs the image's rows against `prev` (raw rows of the same geometry),
   fills up to max_rects merged dirty rects, and copies the changed rows
   into prev so it becomes this frame. Returns the rect count (0 = the
   frames are identical) and the total dirty row count via dirty_rows.
   Detection is pixel-granular for free: the scan reads every byte either
   way; the rects just record where the differences began and ended. */
short now_pixels_diff(CaptureImage *image, Ptr prev,
                      PixelRect *rects, short max_rects, long *dirty_rows);

/* Copies the image's raw rows into dst (row_bytes * height bytes). */
int now_pixels_copy_raw(CaptureImage *image, Ptr dst);

/* Writes the image's palette as RGB triples; returns the byte count
   (0 for direct-colour depths). cap must hold 768 bytes. */
long now_pixels_palette(CaptureImage *image, unsigned char *out, long cap);

/* Exports only the rect rows: per row the col_bytes slice, PackBits'd
   with the usual u16 prefix when pack (and depth >= 8). No palette. */
int now_pixels_export_rects(CaptureImage *image, Boolean pack,
                            const PixelRect *rects, short n_rects,
                            PixelBlob *blob);

#endif
