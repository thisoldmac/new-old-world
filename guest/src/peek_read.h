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

/* Why a read did or did not produce bounds - so the page shows a signal
   about WHERE the path stopped, not a shrug. */
typedef enum {
    kNowPeekReadOk = 0,       /* out holds valid bounds */
    kNowPeekReadNoPlane,      /* extension absent, or anchors not armed */
    kNowPeekReadNoAnchor,     /* no in-partition anchor for the process -
                                 a capture or A5<->PSN correlation miss */
    kNowPeekReadNoWindows,    /* anchor found, but the process has no
                                 windows (its WindowList is empty) */
    kNowPeekReadUnreadable    /* anchor found, but the window walk failed
                                 a validation or sanity check */
} NowPeekReadStatus;

/* Read a GIVEN process's front-window global bounds from its anchor -
   any process, not just the front one, which is the per-process
   `axtree` behaviour: click through the list and read each window.
   Requires the extension with the anchor plane armed (now_peek_arm),
   and the process to have pumped its event loop at least once since
   arming so the filter captured its anchor. Every foreign pointer is
   validated inside the process's partition OR the system heap before it
   is dereferenced - the system heap because some window structures live
   there, which is why a partition-only check read "unreadable". Returns
   which stage it reached; out->valid iff kNowPeekReadOk. Reads only. */
NowPeekReadStatus now_peek_window_for_psn(const ProcessSerialNumber *psn,
                                          NowPeekBounds *out);

#endif /* NOW_PEEK_READ_H */
