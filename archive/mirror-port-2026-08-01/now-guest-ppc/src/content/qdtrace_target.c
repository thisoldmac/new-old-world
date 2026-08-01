/* Picking `qdtrace start`'s target selector. See qdtrace_target.h. */

#include "qdtrace_target.h"

NowQDTarget now_qdtrace_pick_target(int has_a5,
                                    int has_serial_hi, int has_serial_lo,
                                    int has_front, int front_true)
{
    if (has_serial_hi != has_serial_lo) {
        /* Half a serial names a different process, not "no process" -
           the same principle aesend states for its own pair. Checked
           first and unconditionally: a caller that botched the serial
           is told so even if it also sent front or a5. */
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
    case kNowQDTargetSerial:   return "serial";
    case kNowQDTargetFront:    return "front";
    case kNowQDTargetA5:       return "a5";
    case kNowQDTargetNone:
    case kNowQDTargetBadSerial:
    default:                   return "";
    }
}
