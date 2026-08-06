#include "wire_sleep.h"

long now_wire_clamp_idle(long ticks)
{
    if (ticks < 1) {
        return 1;
    }
    if (ticks > 60) {
        return 60;
    }
    return ticks;
}

long now_wire_sleep_ticks(int work_in_flight, int bytes_announced,
                          long idle_ticks)
{
    if (work_in_flight || bytes_announced) {
        return 1;
    }
    return now_wire_clamp_idle(idle_ticks);
}
