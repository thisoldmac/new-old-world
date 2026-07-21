#include "peek.h"

#include <stdio.h>

/* Rung 0: the extension does not exist, and this file says so rather
   than probing for it. The Gestalt selector, the table layout, and the
   version handshake arrive with extension M0; the four states and the
   capability word are already the contract the UI renders, so the
   pages learn to degrade before there is anything to degrade from.
   The needs-restart state additionally requires looking for the file
   in the Extensions folder, which lands with the installer story. */

NowPeekState now_peek_status(unsigned long *caps)
{
    if (caps != NULL) {
        *caps = 0;
    }
    return kNowPeekNotInstalled;
}

void now_peek_status_line(char *out, long cap)
{
    unsigned long ignored;

    switch (now_peek_status(&ignored)) {
    case kNowPeekActive:
        snprintf(out, (size_t)cap, "NOW Extension active");
        break;
    case kNowPeekWrongVersion:
        snprintf(out, (size_t)cap, "NOW Extension needs updating");
        break;
    case kNowPeekNeedsRestart:
        snprintf(out, (size_t)cap,
                 "NOW Extension installed - restart to activate");
        break;
    default:
        snprintf(out, (size_t)cap, "NOW Extension not installed");
        break;
    }
}
