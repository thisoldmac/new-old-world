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

/* The validated shared table, or NULL when the extension is absent or
   the table does not pass the acceptance rule. The pointer is into the
   system heap; treat it as the extension's to write except for
   arm_request (ours). Re-probes Gestalt each call - cheap (a trap). */
const NowPeekTable *now_peek_table(void);

/* Request / release a plane by capability bit(s). Sets or clears the
   arm_request word the extension polls; a no-op when the extension is
   absent. Arming is what makes a dormant plane start doing work
   (docs/resident-components.md). */
void now_peek_arm(unsigned long caps);
void now_peek_disarm(unsigned long caps);

/* **Who wants a plane armed.**
 *
 * `now_peek_arm`/`now_peek_disarm` write one shared bit, so the LAST
 * caller decides for everybody. Two owners wanted the anchor plane and
 * the loser was the mirror: `serve_scene` armed anchors and walked in
 * the same pass, and the Processes page disarmed them whenever it was
 * not the visible module - which is almost always. Only the process
 * pumping in that sliver got an anchor captured, and that process is
 * NOW itself, serving the request. Measured 2026-08-03: ten polls over
 * fifteen seconds, one window every time, and it was always our own.
 *
 * So an owner claims and releases its OWN interest, and the bit is the
 * union. A plane stays armed while anyone wants it and goes dark when
 * the last one lets go. */
typedef enum {
    kNowPeekOwnerScene = 0,       /* scene.request, while mirroring */
    kNowPeekOwnerProcesses,       /* the Processes page, while visible */
    kNowPeekOwnerAct,
    kNowPeekOwnerContent,
    kNowPeekOwnerCount
} NowPeekOwner;

void now_peek_claim(NowPeekOwner owner, unsigned long caps);
void now_peek_release(NowPeekOwner owner, unsigned long caps);

#endif /* NOW_PEEK_H */
