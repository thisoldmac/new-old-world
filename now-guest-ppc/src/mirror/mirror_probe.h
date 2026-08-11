#ifndef NOW_MIRROR_PROBE_H
#define NOW_MIRROR_PROBE_H

#include "mirror_facts.h"

/* Snapshot the one NOW Extension and its four planes. Read-only: host policy
   is intentionally absent, and this module never launches or quits anything. */
void now_mirror_probe(MirrorFacts *facts);

#endif /* NOW_MIRROR_PROBE_H */
