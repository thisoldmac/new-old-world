#include "qdtrace_target.h"

NowQDTarget now_qdtrace_pick_target(int has_a5,
                                    int has_serial_hi, int has_serial_lo,
                                    int has_front, int front_true)
{
    if (has_serial_hi != has_serial_lo) {
        return kNowQDTargetBadSerial;
    }
    if (has_serial_hi && has_serial_lo) {
        return kNowQDTargetSerial;
    }
    if (has_front && front_true) {
        return kNowQDTargetFront;
    }
    if (has_a5) {
        return kNowQDTargetA5;
    }
    return kNowQDTargetNone;
}

const char *now_qdtrace_target_route_name(NowQDTarget target)
{
    switch (target) {
    case kNowQDTargetSerial: return "serial";
    case kNowQDTargetFront:  return "front";
    case kNowQDTargetA5:     return "a5";
    case kNowQDTargetNone:
    case kNowQDTargetBadSerial:
    default:                 return "";
    }
}

int now_qdtrace_target_may_redraw(NowQDTarget target, int same_process)
{
    return same_process
        && (target == kNowQDTargetSerial || target == kNowQDTargetFront);
}
