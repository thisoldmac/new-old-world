#ifndef NOW_SCREENSHOT_H
#define NOW_SCREENSHOT_H

#include <Carbon.h>

/* The screenshot core: capture the screen, encode to PICT (QuickDraw packs
   with PackBits natively while recording), optionally save to the desktop,
   and always measure. One implementation behind the command (local and
   wire), the panel button, and — later — the bulk transfer. */

typedef struct {
    short width, height, depth;
    long raw_bytes;                  /* rowBytes * height, unpacked */
    long pict_bytes;                 /* encoded PICT size */
    long capture_ms;                 /* screen -> GWorld blit */
    long encode_ms;                  /* GWorld -> packed PICT */
    char saved_name[32];             /* "" when not saved */
} ShotStats;

/* depth: 1/2/4/8/16/32. save: write "NOW Shot N" PICT to the desktop.
   Returns 0 and fills stats, or a nonzero capture error with err text. */
int now_screenshot(short depth, Boolean save, ShotStats *stats,
                   char *err, long err_cap);

#endif
