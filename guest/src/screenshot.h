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

#endif
