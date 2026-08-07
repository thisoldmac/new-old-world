/*
 * now_cursor_logic.c - see now_cursor_logic.h for why this is a separate
 * translation unit from the vehicle that calls it.
 */
#include <stddef.h>

#include "now_cursor_logic.h"

int now_cursor_is_foreign(NowPeekI32 raw_h, NowPeekI32 raw_v,
                          NowPeekI32 last_h, NowPeekI32 last_v,
                          int ever_placed)
{
    /* NOTHING TO COMPARE AGAINST IS NOT EVIDENCE OF A PERSON, and
       reading it as such is what made this plane look broken on every
       machine it ever ran on.

       `last` is where this resident last MOVED the device. Before the
       first move there is no such point, and the old spelling compared
       against a zeroed pair - so a pointer resting anywhere but the
       very top-left corner read as foreign, the first act of every boot
       yielded, and the sprite never moved. Driven 2026-08-07: a freshly
       booted guest with the pointer parked at 15,15 answered `asked 1,
       yielded 1` and the arrow stayed put. */
    if (!ever_placed) {
        return 0;
    }
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

int now_cursor_follow_window(NowPeekI32 click_h, NowPeekI32 click_v,
                             NowPeekI32 old_h, NowPeekI32 old_v,
                             NowPeekI32 new_h, NowPeekI32 new_v,
                             int origin_known,
                             NowPeekI32 *out_h, NowPeekI32 *out_v)
{
    if (out_h == NULL || out_v == NULL) {
        return 0;
    }
    /* THE ONLY DECISION IN HERE, and it is a refusal. Without both
       origins there is no delta, and the tempting fallbacks are both
       wrong in the same direction: placing at the click point leaves the
       arrow where the window USED to be, and placing at the requested
       top-left invents a point no observation reported. Either one draws
       a pointer that is lying about what just happened, which is the
       failure this whole plane exists to remove - so it declines, the
       sprite stays where it honestly is, and the act still lands. */
    if (!origin_known) {
        return 0;
    }
    *out_h = click_h + (new_h - old_h);
    *out_v = click_v + (new_v - old_v);
    return 1;
}
