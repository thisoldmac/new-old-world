#ifndef NOW_EXT_CONTINUITY_TRACE_H
#define NOW_EXT_CONTINUITY_TRACE_H

#include "peek_table.h"

/* Bounded resident flight-recorder entries. Callers run in task time; disk
   serialization remains the PPC application's responsibility. */
void now_ext_continuity_trace_tracking_conflict(
    NowPeekI32 live_h, NowPeekI32 live_v,
    NowPeekI32 source_h, NowPeekI32 source_v);
void now_ext_continuity_trace_keyboard_result(
    NowPeekU32 generation, NowPeekU32 action, NowPeekU32 error);

#endif /* NOW_EXT_CONTINUITY_TRACE_H */
