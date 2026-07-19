#ifndef NOW_PREFS_H
#define NOW_PREFS_H

#include <Carbon.h>

typedef struct {
    char host[64];            /* dotted quad, C string */
    unsigned short port;
} NowPrefs;

/* Loads saved settings, or the defaults (10.0.2.2:5250 — the QEMU host
   address, so an emulator guest works out of the box; metal users enter
   their Mac's LAN address once). */
void now_prefs_load(NowPrefs *prefs);
OSErr now_prefs_save(const NowPrefs *prefs);

#endif
