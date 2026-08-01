#ifndef NOW_PEEK_READ_H
#define NOW_PEEK_READ_H

#include <Carbon.h>

/* The application's validated reader over the anchor plane (P1). This
   is where the one foreign-memory read in the whole product happens -
   and it lives HERE, in the application, never in the extension,
   because a fault here is a file copy from fixed
   (docs/resident-components.md).

   Safety rests entirely on peek_validate.c: every pointer is checked
   inside the process's partition OR the system heap before it is
   dereferenced. On classic Mac OS every process shares one address
   space, so the read is possible; the zone check is what keeps a
   corrupt anchor from bus-erroring. A failed check, a stale anchor, or
   an insane result all fail closed. */

enum {
    kNowPeekMaxWindows = 12,      /* windows returned per process */
    kNowPeekTitleMax = 48         /* window-title bytes, MacRoman */
};

typedef struct {
    short top;
    short left;
    short bottom;
    short right;
    char title[kNowPeekTitleMax]; /* may be empty */
} NowPeekWindow;

typedef struct {
    short count;                  /* windows filled in `windows` */
    Boolean more;                 /* the chain was longer than the cap */
    /* The anchor's capture tick (LMGetTicks when the filter last
       sampled this process). Window state is only ever as fresh as the
       target's last event-loop pass - classic Mac OS has no
       cross-process live feed - so the reader reports WHEN, and the
       consumer says so honestly (the AXPeek/qdpeek discipline). Same
       TickCount domain on both sides; age = TickCount() - stamp_ticks. */
    unsigned long stamp_ticks;
    NowPeekWindow windows[kNowPeekMaxWindows];
} NowPeekWindowList;

/* Why a read did or did not produce data - so the page shows a signal
   about WHERE the path stopped, not a shrug. */
typedef enum {
    kNowPeekReadOk = 0,       /* data present */
    kNowPeekReadNoPlane,      /* extension absent, or anchors not armed */
    kNowPeekReadNoAnchor,     /* no fresh in-partition anchor - a capture
                                 or A5<->PSN correlation miss */
    kNowPeekReadNoWindows,    /* anchor found, process has no windows */
    kNowPeekReadUnreadable,   /* anchor found, the walk failed validation */
    kNowPeekReadStub,         /* a plane whose walk is not built yet */
    /* The two answers the oracle (peek_oracle.h) can give that NoAnchor
       used to swallow. Both mean "the plane is working and this process
       still has no usable anchor", which is a different thing to report
       than "nothing has been captured": */
    kNowPeekReadAmbiguous,    /* two anchors claim this partition, and
                                 nothing distinguishes them - refused
                                 rather than guessed */
    kNowPeekReadMismatch      /* an anchor claims it, but its A5 and its
                                 stack base describe different address
                                 spaces: recycled slot, not this process */
} NowPeekReadStatus;

/* All of a GIVEN process's windows - the per-process `axtree` behaviour:
   click through the list, read each process's windows regardless of
   focus. Walks the bounded nextWindow chain from the process's anchor,
   filling bounds + title for each (up to kNowPeekMaxWindows; `more`
   flags a longer chain). Every foreign pointer is validated in the
   process's partition OR the system heap first. Returns which stage it
   reached; on kNowPeekReadOk, out->count >= 1. Reads only. */
NowPeekReadStatus now_peek_windows_for_psn(const ProcessSerialNumber *psn,
                                           NowPeekWindowList *out);

/* Just the window count - the cheap variant for the list badges, which
   need a number per process but not every title. Same validation, no
   title reads. *count is set on Ok and NoWindows. */
NowPeekReadStatus now_peek_window_count(const ProcessSerialNumber *psn,
                                        short *count);

/* Menu-bar titles - STUB for a later pass. The anchor already captures
   each process's MenuList; this walk is not built yet, so it always
   reports kNowPeekReadStub with *count 0. The wiring exists so adding
   the real walk later is app-only. */
NowPeekReadStatus now_peek_menu_titles(const ProcessSerialNumber *psn,
                                       char titles[][32], int max,
                                       int *count);

#endif /* NOW_PEEK_READ_H */
