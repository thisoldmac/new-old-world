#ifndef NOW_MIRROR_JSON_H
#define NOW_MIRROR_JSON_H

#include "mirror_facts.h"
#include "mirror_layout.h"

/* The `mirror` verb's reply, rendered from facts somebody else gathered.

   Split from mirror_probe.c for the reason every emitter in this tree is
   split from its gatherer: the Macintosh half cannot run here, and how a
   fact is SPELLED on the wire is exactly the half worth testing. See
   now-guest-ppc/tests/mirror_json_test.c.

   Writes a whole command.result into `out` and answers how many bytes it
   used. Never writes past `cap`; a reply that would not fit is truncated
   rather than overrun, which cannot happen for a fixed-shape object this
   small and is bounded anyway because the alternative is a malformed
   frame on the wire. */
long now_mirror_json(const MirrorFacts *facts, long id, char *out, long cap);

#endif /* NOW_MIRROR_JSON_H */
