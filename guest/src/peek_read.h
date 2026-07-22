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

/* Why a read did or did not produce bounds - so a "-" on the page
   becomes a signal about WHERE the path stopped, not a shrug. */
typedef enum {
    kNowPeekReadOk = 0,       /* out holds valid bounds */
    kNowPeekReadNoPlane,      /* extension absent, or anchors not armed */
    kNowPeekReadNoAnchor,     /* no fresh in-partition anchor for the
                                 front process - a capture or A5<->PSN
                                 correlation miss */
    kNowPeekReadUnreadable    /* anchor found, but the window walk failed
                                 a partition check or a sanity check - a
                                 layout/validation miss */
} NowPeekReadStatus;

/* Read the FRONT process's front-window global bounds from its anchor.
   Requires the extension present with the anchor plane, the plane armed
   (arm it via now_peek_arm first - the filter needs a pass to begin
   capturing), a fresh anchor for the front process, and every pointer
   on the path validating in-partition. Returns which stage it reached;
   out->valid is set iff the result is kNowPeekReadOk. Reads only. */
NowPeekReadStatus now_peek_front_window(NowPeekBounds *out);

#endif /* NOW_PEEK_READ_H */
