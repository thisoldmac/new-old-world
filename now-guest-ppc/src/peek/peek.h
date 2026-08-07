#ifndef NOW_PEEK_H
#define NOW_PEEK_H

#include <Carbon.h>

#include "peek_table.h"
#include "peek_lease.h"

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

/* Renew the writer heartbeat from the event loop, once per pass.
 *
 * The heartbeat is the resident's proof this application is ALIVE
 * (kNowPeekWriterLeaseTicks, 3 s), and until this existed it was renewed
 * only inside peek calls - so it measured wire-call frequency, not
 * liveness. Any host that polled slower than the lease de-armed every
 * plane between polls, and the first walk after each gap read
 * arm_active before the resident's next pass could re-echo it: every
 * foreign process answered no-plane on exactly the scenes a person was
 * waiting for. That flap is the ledger's "anchor plane is active and
 * binds nothing", measured 2026-08-06 at a 4 s poll cadence. */
void now_peek_idle(void);

/* **Who wants a plane armed.**
 *
 * A direct arm/disarm pair made the LAST caller decide for everybody.
 * Two owners wanted the anchor plane and
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
void now_peek_claim(NowPeekOwner owner, unsigned long caps);
void now_peek_claim_until(NowPeekOwner owner, unsigned long caps,
                          unsigned long expiry_ticks);
void now_peek_release(NowPeekOwner owner, unsigned long caps);
void now_peek_disconnect(void);

/* **Wait, briefly, for a claim to become an ARMED plane.**
 *
 * Claiming publishes a request; the resident echoes it into `arm_active`
 * on its next pass, and until it does every reader gates itself off
 * (`peek_read.c :: resolve` returns no-plane) and answers "I could not
 * look" for the whole machine. A caller that claims and reads in the
 * same breath therefore gets one blind answer per lapse - measured
 * 2026-08-06: a scene walked after a ten-second gap carried NOW's own
 * window and nothing else, and the NEXT one was complete.
 *
 * Bounded and honest: returns 1 only when the plane is genuinely armed,
 * 0 when the deadline passed, no resident answered, or this build does
 * not own the writer. It never asserts an arm it did not observe.
 * Returns as soon as the echo lands (~15 ms measured), so the bound is
 * a ceiling, not a cost. */
int now_peek_settle(unsigned long caps, unsigned long max_ticks);

/* **Which writer session this application is in**, or 0 before it has
 * taken the writer at all. It changes when this build claims the shared
 * table from an absent or dead owner, which is the one moment anything
 * cached ABOUT the machine — as opposed to about the table — stops being
 * evidence. Exported so a cache can expire itself rather than being told
 * to by peek.c, which would have to know about every cache there is. */
unsigned long now_peek_session_epoch(void);

/* **Where the resident should dial, and whether it should dial at all.**
 *
 * The optional resident component answers for the MACHINE while every
 * application on it is starved (plan 012), and to do that it must hold
 * its own connection - it may not borrow this one, because two writers
 * on one frame stream is a corruption the host answers by dropping the
 * link. But it has no preferences, no file access at interrupt time and
 * nobody to ask, so the address can only come from here.
 *
 * Publish AFTER the host has answered, withdraw on every path out.
 * `host_ipv4` is the numeric address in host order - the same UInt32 the
 * wire dialled with, never a name: resolving one needs the application
 * that may be the thing that is starved. */
void now_peek_publish_endpoint(unsigned long host_ipv4, unsigned short port);
void now_peek_withdraw_endpoint(void);

/* Exact resident identity. Returns false for old/short/unknown layouts. */
int now_peek_build_identity(NowPeekBuildIdentity *out);
int now_peek_build_matches(
    const NowPeekU32 expected[kNowPeekIdentityWordCount]);

#endif /* NOW_PEEK_H */
