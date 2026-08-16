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
void now_continuity_service_begin_epoch(unsigned long epoch);
void now_continuity_service_shutdown(void);

#endif
