#ifndef NOW_CONTINUITY_INTAKE_H
#define NOW_CONTINUITY_INTAKE_H

#include <MacTypes.h>

#include "continuity_udp.h"
#include "peek_table.h"

enum {
    kNowContinuityArmUnsupported = 0,
    kNowContinuityArmOK = 1,
    kNowContinuityArmTransportUnavailable = 2
};

enum {
    kNowContinuityKeyMalformed = -2,
    kNowContinuityKeyTargetUnavailable = -1,
    kNowContinuityKeyQueueFull = 0,
    kNowContinuityKeyQueued = 1,
    kNowContinuityKeyBadEpoch = 2
};

typedef struct {
    long id;                 /* 0 for an unsolicited resident exit */
    NowPeekU32 epoch;
    NowPeekU32 state;
    NowPeekU32 accepted_hz;
    NowPeekU32 exit_reason;
    NowPeekU32 accepted_packets;
    NowPeekU32 stale_packets;
    NowPeekU32 malformed_packets;
    NowPeekU32 applied_position_seq;
    NowPeekU32 applied_button_generation;
} NowContinuityReport;

int now_continuity_arm(long id, unsigned short port,
                       unsigned long nonce_hi, unsigned long nonce_lo,
                       unsigned long epoch, unsigned long requested_hz,
                       unsigned long lease_ticks, int fast_pump,
                       unsigned long tracking_options);
int now_continuity_disarm(long id, unsigned long epoch);
int now_continuity_key(unsigned long epoch, unsigned long generation,
                       unsigned long action, unsigned long key_code,
                       unsigned long character, unsigned long modifiers);
/* The host's live modifier word, reported by continuity.key's `modifiers`
   action - a bare modifier change, which the classic Event Manager has no
   event for. It is state and not an edge: the whole word arrives each time
   and the newest one wins.

   IT DOES NOT REACH GetKeys. This application is Carbon and cannot post an
   event or touch the low-memory key map; holding the word here is the half
   of the route that can be built without the resident. Until the resident
   reads it, a modifier pressed mid-drag changes the word and changes nothing
   the Finder can see. Said the same way in continuity-mode.md. */
int now_continuity_modifiers(unsigned long epoch, unsigned long generation,
                             unsigned long modifiers);
/* The word above, or 0 when no epoch is live. */
unsigned long now_continuity_host_modifiers(void);
void now_continuity_disconnect(void);
void now_continuity_shutdown(void);
int now_continuity_take_report(NowContinuityReport *out);
/* The epoch this application is currently armed for, or 0 for none.

   Everything gated on "is Continuity live" reads it from here rather than
   keeping its own copy: an epoch ends in several ways (disarm, lease
   expiry, guest input, disconnect) and a second notion of live would be
   wrong in whichever of them nobody remembered. */
unsigned long now_continuity_live_epoch(void);
/* Is the host holding the primary button down right now?

   The Finder-selection poll asks, because a poll mid-gesture is the exact
   starvation the drag work is trying to avoid: the Finder is inside its
   nested Drag Manager loop and an Apple Event to it will not be answered
   until the button comes up. False when there is no epoch or no resident. */
int now_continuity_button_is_down(void);
unsigned short now_continuity_udp_port(void);
int now_continuity_wants_fast_pump(void);
/* The apply handshake and owner-lease renewal on their own, for the nested
   waits where the wire's state machine may not be re-entered. Safe to call
   at any frequency and from any cooperative task time; a no-op with no live
   epoch. See the definition for what it deliberately does not do. */
void now_continuity_pump(void);
const char *now_continuity_state_name(unsigned long state);
const char *now_continuity_reason_name(unsigned long reason);

#endif
