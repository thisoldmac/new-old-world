#ifndef NOW_CONTINUITY_SERVICE_H
#define NOW_CONTINUITY_SERVICE_H

#include "peek_table.h"

/* The resident publishes a raw 68K code address, never a PPC function
   pointer. These routines own the one Mixed Mode descriptor and the dynamic
   InterfaceLib lookup needed to enter it from cooperative application time. */
int now_continuity_service_ready(const NowPeekContinuityCell *cell);
int now_continuity_service_invoke(NowPeekContinuityCell *cell);
void now_continuity_service_begin_epoch(unsigned long epoch);
void now_continuity_service_shutdown(void);

#endif
