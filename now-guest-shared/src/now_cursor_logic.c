/*
 * now_cursor_logic.c - see now_cursor_logic.h for why this is a separate
 * translation unit from the vehicle that calls it.
 */
#include "now_cursor_logic.h"

int now_cursor_is_foreign(NowPeekI32 raw_h, NowPeekI32 raw_v,
                          NowPeekI32 last_h, NowPeekI32 last_v)
{
    return (raw_h != last_h || raw_v != last_v) ? 1 : 0;
}

int now_cursor_should_yield(NowPeekU32 now, NowPeekU32 foreign_ticks,
                            int owned, NowPeekU32 yield_ticks)
{
    if (owned) {
        return 0;
    }
    /* SUBTRACTION, not `now < foreign_ticks + yield_ticks`. Unsigned
       difference is correct across the TickCount wrap; the addition
       overflows once every 2.3 years of uptime and then this function
       yields forever, which is a cursor that silently stops following
       and a machine nobody can explain. Same rule, same spelling and
       same reason as now_drag_logic.c's elapsed(). */
    return ((NowPeekU32)(now - foreign_ticks) < yield_ticks) ? 1 : 0;
}
