#ifndef NOW_AXPROCESS_H
#define NOW_AXPROCESS_H

#include <Carbon.h>

#include "axwalk.h"
#include "peek_oracle.h"
#include "peek_read.h"

/* The impure half of the walk: one live process, resolved to a memory
   seam the pure parsers can be pointed at.

   THIS IS THE ONLY FILE IN src/axwalk/ THAT TOUCHES THE TOOLBOX, and it
   is the same split peek_oracle.c/peek_read.c already use, for the same
   reason - everything on the other side of it is reachable from a
   native test with no Macintosh in the loop.

   It adds no new Toolbox surface at all: GetProcessInformation,
   LMGetSysZone and TickCount are exactly what peek_read.c already
   calls, which is what makes the crossing from upstream's `retroppc`
   build to NOW's `retrocarbon` one uneventful. Nothing here is
   CALL_NOT_IN_CARBON.

   THE ANCHOR COMES FROM NOW'S ORACLE, NOT UPSTREAM'S. Mirror pairs its
   walk with its own `ax_oracle_match` over its own shared buffer. NOW
   already answers the same question - which anchor slot belongs to this
   partition, and when the answer is "I cannot tell" - through
   peek_oracle.c, written from Mirror's own answers. Two oracles
   disagreeing about which process a pointer belongs to would be a
   serious defect, so upstream's did NOT cross; see the port's report
   and axprocess.c for the one thing it knows that ours does not. */

typedef struct {
    NowAxMemory   memory;         /* hand this to the pure parsers */
    unsigned long window_list;    /* the process's WindowList head; 0 = none */
    unsigned long menu_list;      /* its MenuList handle; 0 = none */
    unsigned long stamp_ticks;    /* TickCount when the anchor was captured */
    unsigned long partition_lo;
    unsigned long partition_size;
    NowPeekAnchorVerdict verdict; /* the oracle's answer, carried through */
} NowAxContext;

/* Resolves `psn` to a bound context. Returns the reader vocabulary
   peek_read.c already uses, so a caller has one set of words for the
   whole plane:

     kNowPeekReadOk          bound; walk it
     kNowPeekReadNoPlane     the extension is absent or anchors unarmed
     kNowPeekReadNoAnchor    no slot claims this partition (the resting
                             state for a process that has not pumped)
     kNowPeekReadAmbiguous   two slots claim it - REFUSED, not guessed
     kNowPeekReadMismatch    a slot's two roots disagree: recycled debris
     kNowPeekReadUnreadable  bound, but the anchor's own pointers fail
                             validation

   No age gate, matching peek_read.c: a stale anchor is REPORTED (the
   stamp comes back) and never refused, because window state is only ever
   as fresh as the target's last pump and a clock cannot improve on that.

   SELF IS NOT SPECIAL-CASED HERE, and that is a real limit rather than
   an oversight: NOW is a Carbon application, so its own window records
   do not sit at the classic 68K offsets this walk reads. Asking for our
   own PSN binds and then walks to nothing useful. peek_read.c answers
   for self through the Window Manager instead; a consumer wanting both
   should do the same. */
NowPeekReadStatus now_ax_bind_process(const ProcessSerialNumber *psn,
                                      NowAxContext *out);

#endif /* NOW_AXPROCESS_H */
