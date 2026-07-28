#ifndef NOW_SCREENSHOT_H
#define NOW_SCREENSHOT_H

#include <Carbon.h>

/* The screenshot core: capture the screen, encode to PICT (QuickDraw packs
   with PackBits natively while recording), optionally save to the desktop,
   and always measure. One implementation behind the command (local and
   wire), the panel button, and — later — the bulk transfer. */

typedef struct {
    short width, height, depth;
    short bands;                     /* CopyBits calls the capture took */
    long raw_bytes;                  /* rowBytes * height, unpacked */
    long pict_bytes;                 /* encoded PICT size */
    long capture_ms;                 /* screen -> GWorld, all bands */
    long encode_ms;                  /* GWorld -> packed PICT */
    long band_min_us, band_max_us;   /* per-band spread, microseconds */
    char saved_name[32];             /* "" when not saved */
} ShotStats;

/* depth: 1/2/4/8/16/32. bands: 1 = one monolithic CopyBits; N splits the
   capture into N banded CopyBits calls, timed per band — the measurement
   probe for interleaved (streaming) capture. save: write "NOW Shot N"
   PICT to the desktop.
   Returns 0 and fills stats, or a nonzero capture error with err text. */
int now_screenshot(short depth, short bands, Boolean save, ShotStats *stats,
                   char *err, long err_cap);

/* Capture just `screen_rect` (global coords) - the anchor plane's payoff,
   a window crop rather than the whole display. Encodes and (save) writes
   the PICT, updates the preview, and fills stats, exactly like
   now_screenshot but bounded to the rect. Returns 0, or a nonzero capture
   error with err text. */
int now_screenshot_rect(const Rect *screen_rect, short depth, Boolean save,
                        ShotStats *stats, char *err, long err_cap);

/* The most recent capture, scaled to preview size while the full pixels
   still existed. Owned by the screenshot path: replaced on the next
   capture, NULL before the first. bounds gets the preview's own
   coordinate space when the preview exists. */
GWorldPtr now_screenshot_preview(Rect *bounds);

#endif
