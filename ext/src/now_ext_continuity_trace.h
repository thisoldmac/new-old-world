#ifndef NOW_EXT_CONTINUITY_TRACE_H
#define NOW_EXT_CONTINUITY_TRACE_H

#include "peek_table.h"

/* Bounded resident flight-recorder entries. Callers run in task time; disk
   serialization remains the PPC application's responsibility. */
void now_ext_continuity_trace_keyboard_result(
    NowPeekU32 generation, NowPeekU32 action, NowPeekU32 error);
void now_ext_continuity_trace_idle_settle(
    NowPeekU32 count, NowPeekU32 position_seq);

#endif /* NOW_EXT_CONTINUITY_TRACE_H */
