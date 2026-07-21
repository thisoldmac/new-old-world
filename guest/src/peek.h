#ifndef NOW_PEEK_H
#define NOW_PEEK_H

#include <Carbon.h>

#include "peek_table.h"

/* The application's view of the NOW Extension - the optional resident
   component (docs/resident-components.md is the family charter,
   docs/processes-and-peek.md the feature ladder). Four states, because
   an installer needs all four to be legible: the file can be absent,
   present but not yet loaded (INITs load at boot only), loaded but the
   wrong major version, or active.

   Capabilities come from the extension's table as bits, never inferred
   from its version: a plane can ship dark in a binary before it has
   earned its metal verification. The bit values are the table
   contract's (contract/peek_table.h) - stated once, aliased here. */

typedef enum {
    kNowPeekNotInstalled = 0, /* no Gestalt answer, no file           */
    kNowPeekNeedsRestart,     /* file in Extensions, no Gestalt yet   */
    kNowPeekWrongVersion,     /* Gestalt answered, major differs      */
    kNowPeekActive
} NowPeekState;

/* Capability bits, reserved now so the UI can gate on them from day
   one. None are claimed until the extension exists. */
enum {
    kNowPeekCapAnchors = kNowPeekTableCapAnchors, /* P1: window bounds */
    kNowPeekCapTree = kNowPeekTableCapTree        /* P2: semantic tree */
};

/* The current state; caps may be NULL. Cheap enough for idle paths. */
NowPeekState now_peek_status(unsigned long *caps);

/* One placard-ready line for the current state. */
void now_peek_status_line(char *out, long cap);

#endif /* NOW_PEEK_H */
