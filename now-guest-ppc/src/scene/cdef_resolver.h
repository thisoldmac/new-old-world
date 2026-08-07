#ifndef NOW_CDEF_RESOLVER_H
#define NOW_CDEF_RESOLVER_H

#include "control_cdef.h"

/* Ask the RESOURCE MANAGER to name a foreign control's definition
 * function. See control_cdef.h for what the answer is worth.
 *
 * WHY THIS IS ITS OWN SEAM. `scene_walk.c` is Toolbox-free on purpose -
 * it takes a bound memory seam and is compiled by the host `cc` for its
 * native test - and `GetResInfo` is a Toolbox call. So the walk declares
 * this and the linker supplies either the real one (`cdef_resolver.c`)
 * or the test's stub, exactly as `semantic_client.h` already does.
 *
 * WHAT IT MAY BE ASKED. Only a `def_proc` the walk already classified as
 * living in the SYSTEM heap - which is the zone the walk validated, and
 * also the only zone whose CDEFs are in this process's resource chain.
 * A definition function in the target's own partition belongs to a
 * resource file we have not opened and never will; asking about it would
 * be a lookup that cannot succeed. The caller enforces that, and the
 * implementation re-checks it against the same zone bounds rather than
 * trusting a caller with a raw address.
 *
 * THE VARIATION CODE, and why it is not read off the field. Inside
 * Macintosh says a control's variation code rides in the high byte of
 * `contrlDefProc`, which would mean the raw longword is not an address -
 * and `axwalk.h` deliberately refuses to mask on that say-so, because a
 * 24-bit mask on a 32-bit-clean machine is its own defect. This
 * resolver settles it by ASKING rather than deciding: it offers the
 * Resource Manager the raw longword first and the masked one second, and
 * whichever one the Resource Manager recognises as a `CDEF` is the
 * handle - so a nonzero variant is reported only when the machine has
 * confirmed the byte was not part of the address.
 *
 * Returns a `NowCdefState`. `*out_id` and `*out_variant` are meaningful
 * only for `kNowCdefNamed`. */
short now_cdef_resolve(unsigned long def_proc,
                       unsigned long system_lo, unsigned long system_hi,
                       short *out_id, short *out_variant);

#endif
