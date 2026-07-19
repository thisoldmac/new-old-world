#ifndef NOW_PREFS_H
#define NOW_PREFS_H

#include <Carbon.h>

#define kNowMaxSavedWindows 8

typedef struct {
    short left, top, right, bottom;   /* global content bounds */
    short depth;
} NowWindowState;

typedef struct {
    char host[64];            /* dotted quad, C string */
    unsigned short port;
    /* -1: never saved (first run — open one default window).
       0..N: restore exactly these windows, including none. */
    short window_count;
    NowWindowState windows[kNowMaxSavedWindows];
} NowPrefs;

/* Loads saved settings, or the defaults (10.0.2.2:5250 — the QEMU host
   address, so an emulator guest works out of the box; metal users enter
   their Mac's LAN address once). Reads both the v1 (host/port only) and v2
   (adds window session) record formats. */
void now_prefs_load(NowPrefs *prefs);
OSErr now_prefs_save(const NowPrefs *prefs);

#endif
