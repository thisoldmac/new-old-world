#ifndef NOW_MIRROR_CONSENT_H
#define NOW_MIRROR_CONSENT_H

/* The rule that turns the four retired per-plane Mirror gates into the one
   master consent, written down ONCE and deliberately Toolbox-free so the
   host cc compiles it and a test can watch it.

   Three callers, and they are the reason it is not inlined at any of them:
   the preferences migration (a V22..V28 record on this Mac), the wire
   (the four compatibility fields a current guest still sends), and — on
   the other half — a host reading a guest that predates `enabled`. Three
   places applying the same rule from memory is exactly the drift this
   project has paid for before.

   AND, not OR: a consent that widens because one of four switches was on
   is the wrong kind of surprise. It is also its own inverse against
   now_mirror_consent_to_gates(), so a record round-trips through either
   build unchanged. */

/* Plain int rather than Boolean: this file must compile where MacTypes.h
   does not exist. Non-zero is on, exactly as the stored shorts are. */
int now_mirror_consent_from_gates(int structure, int finder_complements,
                                  int content, int foreground_cycle);

/* The four values a current build writes into the retired slots: every one
   of them is the master. A separate call rather than four assignments so
   the pairing with the collapse above has a name a test can hold. */
int now_mirror_consent_to_gates(int consent);

#endif /* NOW_MIRROR_CONSENT_H */
