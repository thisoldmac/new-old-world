#ifndef NOW_GESTALT_JSON_H
#define NOW_GESTALT_JSON_H

#include "commands.h"

/* The `gestalt` command's serializer, split out of commands.c so it can be
   compiled and run by the host cc — it is pure C over GestaltRow and touches
   no Toolbox. That split is the point: the version that lived inline wrote
   every structural byte (`[`, `]`, `,` and the quotes around each label and
   value) with a bare `out[pos++]`, checking the cap only around the escaped
   text and once more at the very end, AFTER the unchecked writes. A gather
   large enough to fill the wire's 3072-byte result buffer would have run
   past it rather than truncating, and nothing here could run the case. */

/* Below this, a result cannot be written at all — the envelope plus the
   room held back for the closing braces and the truncation notice do not
   fit. A caller passing less gets an empty string, not half a message. */
#define kGestaltJsonMinCap 192

/* Writes a complete command.result for `id` into `out` (at most cap - 1
   characters plus a NUL, never one byte more), carrying every row in `rows`
   whose group appears in the NULL-terminated `groups` list, in the order
   `groups` gives.

   Returns the number of rows that did not fit — 0 when the whole reply is
   there. A row is written whole or not at all, so the JSON is well-formed at
   any cap, and when rows are dropped the reply says so in a `notice` group
   rather than arriving silently short: a truncated machine and a machine
   with fewer facts to report look identical otherwise, and the host has no
   way to tell them apart. Room for that notice is held back from `cap` up
   front, because a buffer too full for rows is also too full for the
   sentence explaining why. */
int now_gestalt_result_json(long id, const GestaltRow *rows, int count,
                            const char *const *groups, char *out, long cap);

#endif
