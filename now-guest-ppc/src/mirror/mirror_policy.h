#ifndef NOW_MIRROR_POLICY_H
#define NOW_MIRROR_POLICY_H

#include <MacTypes.h>

/* This Mac's own answer to one question: may it be mirrored? Every
   guest-side Mirror boundary — structure claims, Finder complements,
   drawing traces, foreground discovery — asks this and nothing else.

   It used to be four questions, one per observation strategy, and they
   retired on 2026-08-15 because the host's controls are five PLANES and
   the two vocabularies never mapped one-to-one: a person reading either
   page could not predict the other. Granularity moved to the host, whole.
   The veto did not move: false here refuses everything, whatever the host
   permits. */

typedef struct MirrorPolicy {
    Boolean enabled;
} MirrorPolicy;

void now_mirror_policy_get(MirrorPolicy *out);
Boolean now_mirror_policy_enabled(void);
OSErr now_mirror_policy_set(Boolean enabled);
/* The consent checkbox's label, here rather than in the module for the
   same reason every other string on that page is: the host cc compiles
   this file, so a test can read what a person would read. */
const char *now_mirror_policy_name(void);

#endif /* NOW_MIRROR_POLICY_H */
