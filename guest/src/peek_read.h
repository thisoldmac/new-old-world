#ifndef NOW_PEEK_READ_H
#define NOW_PEEK_READ_H

#include <Carbon.h>

/* The application's validated reader over the anchor plane (P1). This
   is where the one foreign-memory read in the whole product happens -
   and it lives HERE, in the application, never in the extension,
   because a fault here is a file copy from fixed
   (docs/resident-components.md).

   Safety rests entirely on peek_validate.c: every pointer is checked
   inside the front process's partition (from GetProcessInformation)
   before it is dereferenced. On classic Mac OS every process shares one
   address space, so the read is possible; the partition check is what
   keeps a corrupt anchor from bus-erroring. A failed check, a stale
   anchor, or an insane result all fail closed - the caller falls back
   to whole-screen behaviour and says so. */

typedef struct {
    short top;
    short left;
    short bottom;
    short right;
    Boolean valid;
} NowPeekBounds;

/* Fill the FRONT process's front-window global bounds from its anchor.
   Requires the extension present with the anchor plane, the plane armed
   (arm it via now_peek_arm before relying on this - the filter needs a
   pass to begin capturing), a fresh anchor for the front process, and
   every pointer on the path validating. Returns out->valid, and false
   on any miss. Reads only; changes nothing. */
Boolean now_peek_front_window(NowPeekBounds *out);

#endif /* NOW_PEEK_READ_H */
