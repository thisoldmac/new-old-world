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

/* ONE WINDOW, BOTH OF ITS REGIONS.
 *
 * `top/left/bottom/right` is the STRUCTURE region - the frame a person
 * sees. `cont_*` is the CONTENT region, which is what a control's local
 * rect is relative to and what the scene's `windows[].rect` is derived
 * from.
 *
 * The content region is here because this reader and axwalk.c each used
 * to return ONE region and a different one, from separate offset tables
 * with opposite failure policies, and the scene consumed both - so
 * `windows[].rect` had three derivations and one of them converted
 * between the regions with a fixed constant. Both readers now return
 * both regions, from the machine, so the scene has one derivation and
 * nothing has to guess a title bar's height. See axwalk.h, which carries
 * the same note against the same fields. */
typedef struct {
    short top;
    short left;
    short bottom;
    short right;
    short cont_top;
    short cont_left;
    short cont_bottom;
    short cont_right;
    char title[kNowPeekTitleMax]; /* may be empty */
    /* The WindowRecord this row was read from, so a SECOND reader can
       return to the same window without re-deriving which one it is.
       The scene's control and text planes need exactly that, and
       matching by chain position instead would silently misfile every
       control after the first window this reader skipped.
       ZERO FOR OUR OWN WINDOWS: self is read through the Window Manager
       (see read_own_windows), where there is no classic record to name,
       and a foreign-offset walk over a Carbon window would be wrong
       rather than merely unavailable. */
    unsigned long address;
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

/* Menu-bar titles for a given process - the walk that used to be a
   declared stub and is one no longer (2026-07-31). It binds the process
   through the same anchor plane the window walk uses and reads the Menu
   Manager's list through src/axwalk/, so every byte crosses the same
   validated boundary.

   Returns kNowPeekReadOk with *count possibly ZERO: unlike the window
   calls, an empty answer here is success, because a faceless process
   genuinely has no menu bar and there is no NoMenus in this vocabulary
   to spend on it. A list that will not parse is kNowPeekReadUnreadable;
   the anchor verdicts come back unchanged.

   SELF REPORTS kNowPeekReadStub, precisely. NOW is a Carbon application,
   so its own menu structures are not at the classic offsets this walk
   reads - and "a plane whose walk is not built yet" is exactly true of
   NOW's own menu bar, which would need the Toolbox rather than a
   foreign-memory walk. */
NowPeekReadStatus now_peek_menu_titles(const ProcessSerialNumber *psn,
                                       char titles[][32], int max,
                                       int *count);

#endif /* NOW_PEEK_READ_H */
