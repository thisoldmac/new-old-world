#ifndef NOW_CONTINUITY_SERVICE_H
#define NOW_CONTINUITY_SERVICE_H

#include "peek_table.h"

/* The resident publishes a raw 68K code address, never a PPC function
   pointer. These routines own the one Mixed Mode descriptor and the dynamic
   InterfaceLib lookup needed to enter it from cooperative application time. */
int now_continuity_service_ready(const NowPeekContinuityCell *cell);
int now_continuity_service_invoke(NowPeekContinuityCell *cell);

/* V14: drain the resident's drag observer into the log. Called from the
   Mirror's slow idle observer, NOT from the service above - the observer
   is armed by the act plane too, and there may be no Continuity epoch. */
void now_continuity_drag_observe_idle(void);

/* V15: the identity the Drag Manager handed the resident's tracking
   handler at drag begin, lifted out of the cell as a plain struct.
   No selection is involved anywhere in producing it.

   `seq` is the resident's drag-begin sequence and is the thing that makes
   this a DRAG rather than a file: it moves for every gesture, so a second
   pick-up of the same icon is distinguishable from the first. Zero means
   no whole record is published.

   TWO READERS, DELIBERATELY. The drain reads it to publish a generation;
   the grab confirmation reads it again, seconds later, to check that the
   drag it is about to serve is still the drag it was minted from. Both
   want the same three lines of tear-free read, so they share them. */
typedef struct {
    unsigned long seq;
    short vref;
    long parid;
    unsigned char name[64];       /* Pascal, as the FSSpec had it */
    int is_hfs;                   /* the first item carried an HFS flavor */
} NowContinuityDragIdentity;

/* Returns 1 when a whole record was read. The cell is written by another
   context, so the caller gets the same odd/even sequence discipline the
   drain uses; a torn or absent record is 0 rather than a half-identity. */
int now_continuity_drag_identity(NowContinuityDragIdentity *out);
void now_continuity_service_begin_epoch(unsigned long epoch);
void now_continuity_service_shutdown(void);

#endif
