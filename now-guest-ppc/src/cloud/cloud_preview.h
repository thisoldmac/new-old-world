#ifndef NOW_CLOUD_PREVIEW_H
#define NOW_CLOUD_PREVIEW_H

/* The photo preview's decidable half, pure so the host cc can test it
   (cloud_preview_test.c): what depth to ask for, whether a
   preview.begin is coherent enough to allocate for, and where the
   arrived pixels land in the pane. The Toolbox half — the GWorld, the
   CopyBits — lives in cloud_photos_view.c and reads these numbers. */

#if TARGET_API_MAC_CARBON
#include <MacTypes.h>
#endif

enum {
    /* The most a preview.begin may announce before it is refused as
       malformed: the host clamps the box to 640x480 and 8 bits, and a
       begin past that ceiling is not a bigger preview, it is a peer
       this code should not allocate for. */
    kCloudPreviewMaxBytes = 640L * 480L
};

typedef struct {
    long id;
    long transfer;
    long width;
    long height;
    long depth;                       /* 1 or 8 */
    long row_bytes;
    long bytes;                       /* row_bytes * height, stated */
} CloudPreviewBegin;

/* Parses and VALIDATES a preview.begin frame: 1 when every field is
   present and coherent (dimensions positive, depth 1 or 8, row_bytes
   at least the packed minimum for the width, bytes == row_bytes *
   height and under the ceiling), else 0 — a malformed begin reads as
   refusable, never as an allocation. */
int cloud_preview_parse_begin(const char *reply, CloudPreviewBegin *out);

/* What depth to ask for, from the screen's actual pixel size: 8 for
   any screen that can index (>= 8), 1 below that — a 4-bit screen
   draws a 1-bit preview honestly, where 8-bit indices would have to be
   mapped by CopyBits through tables this arc does not ship. */
long cloud_preview_ask_depth(long screen_depth);

/* Where the arrived pixels (sw x sh) land inside a ww x wh well:
   scaled to FIT — the screenshots well's arithmetic, upscaling a small
   image to the pane the way the spec's "zoomed to fit" asks. Returns
   the destination size; the caller centers it. Zero or negative input
   yields a 1x1 answer rather than a divide. */
void cloud_preview_fit(long sw, long sh, long ww, long wh,
                       long *dw, long *dh);

#endif /* NOW_CLOUD_PREVIEW_H */
