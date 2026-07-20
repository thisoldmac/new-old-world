#ifndef NOW_PREFS_H
#define NOW_PREFS_H

#include <Carbon.h>

typedef struct {
    char host[64];            /* dotted quad, C string */
    unsigned short port;

    /* screenshot tuning (the panel's settings; commands inherit them) */
    short shot_depth;         /* 1/2/4/8/16/32, default 8 */
    Boolean shot_pack;        /* compress on the wire (PackBits), default on */
    short chunk_kb;           /* bulk chunk size in KB, 1..32, default 8 */
    short pace_ms;            /* inter-chunk pacing, default 0 (Orinoco) */

    /* reconnect cadence: 0 = adaptive backoff (2s doubling to 30s),
       else a fixed retry every N seconds */
    short retry_secs;

    /* window session: what was open, restored on relaunch */
    Boolean panel_open;
    Boolean console_open;
    Rect panel_rect;          /* content bounds; empty = default position */
    Rect console_rect;
} NowPrefs;

/* Loads saved settings, or the defaults (10.0.2.2:5250 — the QEMU host
   address — 8-bit, pack on, 8K chunks, no pacing, panel open). Reads the
   v1/v2 record formats (host/port only) as well as v3 and v4. */
void now_prefs_load(NowPrefs *prefs);
OSErr now_prefs_save(const NowPrefs *prefs);

#endif
