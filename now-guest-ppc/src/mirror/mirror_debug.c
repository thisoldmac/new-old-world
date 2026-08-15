#include "mirror_debug.h"

#include <string.h>

/* Session-scoped and default OFF — the header says why. Single-threaded
   task time, so a plain int is the whole mechanism. */
static int g_debug_on;

int now_mirror_debug_on(void)
{
    return g_debug_on;
}

void now_mirror_debug_set(int on)
{
    g_debug_on = on ? 1 : 0;
}

int now_mirror_debug_parse(const char *action)
{
    if (action == NULL) {
        return kNowMirrorDebugStatus;
    }
    if (strcmp(action, "on") == 0) {
        return kNowMirrorDebugOn;
    }
    if (strcmp(action, "off") == 0) {
        return kNowMirrorDebugOff;
    }
    return kNowMirrorDebugStatus;
}
